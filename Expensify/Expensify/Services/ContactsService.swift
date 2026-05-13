import Foundation
import Contacts
import Observation

/// Local-only contact matcher. Reads the user's Contacts on demand, builds
/// an index of "normalized name" → contact, and answers two questions for
/// the rest of the app:
///
///   1. `match(for transaction:)` → does this transaction's payee map to
///      a contact in your phone? Used to overlay the contact's display
///      name (and later, their photo) onto the row.
///   2. `shouldClassifyAsP2P(transaction:)` → if there's a contact match,
///      this is almost certainly a personal transfer regardless of what
///      the backend's tier chain said. Used to force-tag at display time.
///
/// Privacy:
///   • Contacts NEVER leave the device. No network calls. No sync.
///   • The CN photo data is held in memory only while the app is running;
///     it's not written to disk.
///   • Reading contacts requires user permission (Info.plist key:
///     `NSContactsUsageDescription`); the first call to refresh() will
///     trigger the iOS permission prompt.
///
/// One @Observable instance, injected via .environment(). Views consume
/// matches via `contactsService.match(for: tx)` — synchronous lookup, no
/// async hop, because the index is held in-memory after refresh.
@MainActor
@Observable
final class ContactsService {
    /// Authorization state — drives whether we show a "grant access" CTA
    /// somewhere in the UI later (not built yet). For now we just request.
    enum Authorization: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
        case limited
    }

    var authorization: Authorization = .notDetermined
    var lastError: String? = nil

    /// Normalized first-token → list of contacts whose name starts with
    /// that token. Index is rebuilt on each refresh().
    /// Why first-token: bank emails almost always render UPI payee names
    /// as "FIRSTNAME LASTNAME" (e.g. "RAJESH KUMAR"). Matching by the
    /// first word is the cheapest, most accurate heuristic short of fuzzy
    /// name resolution.
    private var indexByFirstToken: [String: [Contact]] = [:]

    /// Full list — kept so we can support "any token" fallback matching.
    private var allContacts: [Contact] = []

    struct Contact: Hashable {
        let id: String          // CNContact.identifier
        let displayName: String // "Sneha R" — preserves the user's casing
        let givenName: String
        let familyName: String
        let phoneNumbers: [String]
        let hasPhoto: Bool      // image data fetched lazily (see imageData(for:))
    }

    /// Photo image data, keyed by contact id. Populated lazily on demand
    /// so the index build doesn't pull every JPEG into memory.
    private var photoCache: [String: Data] = [:]
    /// Snapshot of CNContacts we fetched — used to lazy-load photos.
    private var cnContactsById: [String: CNContact] = [:]

    /// Fetch authorization status from iOS without prompting. Cheap; safe
    /// to call from view onAppear.
    func refreshAuthorizationStatus() {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .restricted: authorization = .restricted
        case .authorized: authorization = .authorized
        case .limited: authorization = .limited
        @unknown default: authorization = .notDetermined
        }
    }

    /// Ask iOS for permission (no-op if already decided), then load and
    /// index contacts on success. Safe to call multiple times.
    func requestAccessAndLoad() async {
        let store = CNContactStore()
        do {
            let granted = try await store.requestAccess(for: .contacts)
            refreshAuthorizationStatus()
            if granted || authorization == .authorized || authorization == .limited {
                await reload(using: store)
            }
        } catch {
            lastError = error.localizedDescription
            refreshAuthorizationStatus()
        }
    }

    private func reload(using store: CNContactStore) async {
        await Task.detached(priority: .utility) {
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactImageDataAvailableKey as CNKeyDescriptor,
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            ]

            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            var fetched: [Contact] = []
            var cnById: [String: CNContact] = [:]
            do {
                try store.enumerateContacts(with: request) { cn, _ in
                    let formatter = CNContactFormatter()
                    formatter.style = .fullName
                    let display = formatter.string(from: cn) ?? "\(cn.givenName) \(cn.familyName)".trimmingCharacters(in: .whitespaces)
                    guard !display.isEmpty else { return }
                    let phones = cn.phoneNumbers.map { $0.value.stringValue }
                    let c = Contact(
                        id: cn.identifier,
                        displayName: display,
                        givenName: cn.givenName,
                        familyName: cn.familyName,
                        phoneNumbers: phones,
                        hasPhoto: cn.imageDataAvailable
                    )
                    fetched.append(c)
                    cnById[cn.identifier] = cn
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
                return
            }

            await MainActor.run {
                self.allContacts = fetched
                self.cnContactsById = cnById
                self.indexByFirstToken = Self.buildIndex(from: fetched)
            }
        }.value
    }

    private static func buildIndex(from contacts: [Contact]) -> [String: [Contact]] {
        var out: [String: [Contact]] = [:]
        for c in contacts {
            let token = Self.normalize(c.givenName.isEmpty ? c.displayName : c.givenName)
                .split(separator: " ")
                .first
                .map(String.init) ?? ""
            guard !token.isEmpty else { continue }
            out[token, default: []].append(c)
        }
        return out
    }

    // MARK: - Matching

    /// Returns the best-matching contact for a transaction's payee, or nil.
    ///
    /// Match priority:
    ///   1. First-token match: "RAJESH KUMAR" → contact with first name "Rajesh"
    ///   2. Substring match on full display name (covers nicknames /
    ///      single-name contacts like "Sneha")
    ///
    /// Only matches when the transaction is BOTH outbound AND uses the
    /// account-instrument (UPI from your bank account) — credit-card
    /// transactions to "RAJESH KUMAR" are restaurant tips, not P2P.
    func match(for transaction: Transaction) -> Contact? {
        guard transaction.direction == .out else { return nil }
        guard transaction.instrument.hasPrefix("account_") else { return nil }
        guard !indexByFirstToken.isEmpty else { return nil }

        let payee = transaction.merchantRaw
        let normalized = Self.normalize(payee)
        let firstToken = normalized.split(separator: " ").first.map(String.init) ?? ""

        // Index hit on first token — narrow to a small set, pick best.
        if !firstToken.isEmpty, let candidates = indexByFirstToken[firstToken] {
            if candidates.count == 1 { return candidates[0] }
            // Multiple "Rajesh"es in contacts. Try to disambiguate by also
            // matching the family name token from the payee against any
            // contact's family name.
            let payeeTokens = Set(normalized.split(separator: " ").map(String.init))
            for c in candidates {
                let family = Self.normalize(c.familyName)
                if !family.isEmpty, payeeTokens.contains(family) {
                    return c
                }
            }
            return candidates[0]
        }

        // Fallback: substring match anywhere.
        for c in allContacts {
            let nd = Self.normalize(c.displayName)
            if !nd.isEmpty, normalized.contains(nd) || nd.contains(normalized) {
                return c
            }
        }
        return nil
    }

    /// Should we client-side override this transaction's category to P2P?
    /// True iff there's a contact match AND the existing category isn't
    /// already a more-confident merchant signal (alias / autopay).
    func shouldClassifyAsP2P(_ transaction: Transaction) -> Bool {
        guard match(for: transaction) != nil else { return false }
        // Don't override known merchants — if our backend already auto-
        // tagged via alias (e.g. "BUNDL TECHNOLOGIES" → Swiggy), trust
        // that over a contact name collision.
        switch transaction.signalSource {
        case .alias, .autopayAlias, .merchantPattern, .places:
            return false
        default:
            return true
        }
    }

    /// Get the contact's photo data. Loads from the CNContact on first
    /// request, then caches. Returns nil if the contact has no photo or
    /// permission was revoked.
    func imageData(for contact: Contact) -> Data? {
        if let cached = photoCache[contact.id] { return cached }
        guard contact.hasPhoto, let cn = cnContactsById[contact.id] else { return nil }
        // Re-fetch the contact with image data — the initial enumeration
        // didn't pull the JPEG bytes to keep memory low.
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        do {
            let full = try store.unifiedContact(withIdentifier: cn.identifier, keysToFetch: keys)
            if let data = full.thumbnailImageData {
                photoCache[contact.id] = data
                return data
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - Normalization

    /// Strip punctuation, collapse whitespace, lowercase. Used as the
    /// canonical comparison form for names.
    private static func normalize(_ s: String) -> String {
        let kept = s.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(kept)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.lowercased()
    }
}
