import Foundation
import Contacts
import Observation

/// Local-only contact matcher. Reads the user's Contacts on demand, builds
/// a phone-number index (and keeps the full list for name fallback), and
/// answers one question for the rest of the app:
///
///   `match(for transaction:)` — was this UPI transaction sent to someone
///   in your address book? Two-pass:
///
///     1. Phone-number match (high confidence). The VPA's local part
///        parses as a digit string that's also one of the contact's
///        phone numbers.
///     2. Multi-token name match with strict uniqueness (medium). The
///        bank-payee text has ≥2 meaningful tokens, and exactly one
///        contact has all of them in their display name.
///
/// Pass 2 deliberately drops single-letter tokens (initials like "R")
/// and refuses to guess when multiple contacts could match — that's
/// what stopped the earlier "Sneha Bubbly → Sneha Appa" false positive.
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

    /// Normalized last-10-digit phone → list of contacts that have that
    /// number. Phone is the only field that's actually unique — name
    /// matching gave us false positives ("Sneha Bubbly" matching to
    /// "Sneha Appa" because both start with "Sneha"). UPI VPAs often
    /// embed the phone number in the local part (e.g. `9876543210@ybl`),
    /// so when we can extract a phone from the VPA we lookup here.
    private var indexByPhone: [String: [Contact]] = [:]

    /// Full list — used for diagnostics and the count, not for matching.
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
            // Pull both thumbnail AND full image keys. Some contacts have
            // only the full-resolution photo (no auto-generated thumbnail
            // — this happens when the photo was attached via certain
            // sync paths). Falling back to imageData here means we never
            // miss a photo that exists.
            //
            // Cost is bounded: thumbnails are tiny (~4KB), full images
            // are bigger (~50-200KB) but only loaded when no thumbnail
            // exists. Typical iPhone has 200-500 contacts, ~5-10% with
            // photos — peak memory still well under 10MB.
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactImageDataAvailableKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor,
                CNContactImageDataKey as CNKeyDescriptor,
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            ]

            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            var fetched: [Contact] = []
            var cnById: [String: CNContact] = [:]
            var photos: [String: Data] = [:]
            var photoStats = (withThumb: 0, withFull: 0, available: 0)
            do {
                try store.enumerateContacts(with: request) { cn, _ in
                    let formatter = CNContactFormatter()
                    formatter.style = .fullName
                    let display = formatter.string(from: cn) ?? "\(cn.givenName) \(cn.familyName)".trimmingCharacters(in: .whitespaces)
                    guard !display.isEmpty else { return }
                    let phones = cn.phoneNumbers.map { $0.value.stringValue }
                    let hasPhoto = cn.imageDataAvailable
                    let c = Contact(
                        id: cn.identifier,
                        displayName: display,
                        givenName: cn.givenName,
                        familyName: cn.familyName,
                        phoneNumbers: phones,
                        hasPhoto: hasPhoto
                    )
                    fetched.append(c)
                    cnById[cn.identifier] = cn
                    if hasPhoto {
                        photoStats.available += 1
                        if let data = cn.thumbnailImageData {
                            photos[cn.identifier] = data
                            photoStats.withThumb += 1
                        } else if let data = cn.imageData {
                            // Fall back to full image when no thumbnail
                            // exists. iOS will downsample at render time.
                            photos[cn.identifier] = data
                            photoStats.withFull += 1
                        }
                    }
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
                self.indexByPhone = Self.buildPhoneIndex(from: fetched)
                self.photoCache = photos
                #if DEBUG
                print("[ContactsService] indexed \(fetched.count) contacts; photos: \(photos.count) cached (\(photoStats.withThumb) thumb + \(photoStats.withFull) full); \(photoStats.available) marked imageDataAvailable")
                #endif
            }
        }.value
    }

    /// Build a phone → contacts index. Each phone number is normalized
    /// to its last 10 digits so that "+91 98765 43210" and "9876543210"
    /// collapse to the same key. A contact with multiple phone numbers
    /// (work + personal) appears under each of its normalized keys.
    private static func buildPhoneIndex(from contacts: [Contact]) -> [String: [Contact]] {
        var out: [String: [Contact]] = [:]
        for c in contacts {
            for raw in c.phoneNumbers {
                guard let key = Self.normalizePhone(raw) else { continue }
                out[key, default: []].append(c)
            }
        }
        return out
    }

    /// Reduce a phone number string to its canonical last-10-digit form.
    /// Returns nil for strings with fewer than 10 digits (probably a
    /// landline / short code that won't match a VPA anyway).
    static func normalizePhone(_ raw: String) -> String? {
        let digits = raw.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()
        guard digits.count >= 10 else { return nil }
        return String(digits.suffix(10))
    }

    /// Try to extract a 10-digit phone number from a UPI VPA's local part.
    /// Returns nil when the local part isn't a phone (e.g. `sneha.r@oksbi`
    /// where the user-handle is a name, not a number).
    ///
    /// Examples that match:
    ///   - `9876543210@ybl`     → `9876543210`
    ///   - `919876543210@paytm` → `9876543210`
    ///   - `+919876543210@upi`  → `9876543210`
    /// Examples that don't:
    ///   - `sneha.r@oksbi`      → nil
    ///   - `bob.smith@axl`      → nil
    static func phoneFromVpa(_ vpa: String) -> String? {
        guard let atIndex = vpa.firstIndex(of: "@") else { return nil }
        let local = String(vpa[..<atIndex])
        // Allow an optional leading `+` and otherwise only digits.
        // Pattern: `^\+?\d{10,12}$`
        let isPhoneShaped = local.range(of: #"^\+?\d{10,12}$"#, options: .regularExpression) != nil
        guard isPhoneShaped else { return nil }
        return normalizePhone(local)
    }

    // MARK: - Matching

    /// Returns the contact a transaction was sent to. Two passes:
    ///
    ///   1. **Phone match** (highest confidence): VPA's local part parses
    ///      as a phone number that lives in the address book.
    ///   2. **Multi-token name match** (medium confidence): the bank's
    ///      payee text has ≥2 meaningful tokens (single-letter initials
    ///      dropped), AND **exactly one** contact has all of those tokens
    ///      in their display name. Returning nil on ambiguity is the
    ///      whole point — it's what stopped "Sneha Bubbly" matching to
    ///      "Sneha Appa" before.
    ///
    /// Only runs for outbound UPI transactions from your bank account
    /// (`account_*` instrument). Credit-card transactions to a name look
    /// like personal transfers but are actually tips/services.
    func match(for transaction: Transaction) -> Contact? {
        guard transaction.direction == .out else { return nil }
        guard transaction.instrument.hasPrefix("account_") else { return nil }

        // --- Pass 1: phone-based match -----------------------------------
        if let vpa = transaction.vpa,
           let phone = Self.phoneFromVpa(vpa),
           let phoneCandidates = indexByPhone[phone],
           !phoneCandidates.isEmpty {
            return phoneCandidates[0]
        }

        // --- Pass 2: strict multi-token name match -----------------------
        let payeeTokens = Self.nameTokens(transaction.merchantRaw)
        // Need at least 2 meaningful tokens — a single name like "SNEHA"
        // is ambiguous against any address book that has multiple Snehas.
        guard payeeTokens.count >= 2 else { return nil }

        let payeeSet = Set(payeeTokens)
        let nameCandidates = allContacts.filter { contact in
            let contactSet = Set(Self.nameTokens(contact.displayName))
            // Every payee token must appear in the contact's name set.
            return payeeSet.isSubset(of: contactSet)
        }
        // Match only on uniqueness — if two contacts both satisfy, drop
        // the match rather than guess.
        return nameCandidates.count == 1 ? nameCandidates[0] : nil
    }

    /// Normalize a name into its meaningful tokens. Lowercases, strips
    /// punctuation, drops single-character tokens (initials like "R" or
    /// "K" are too noisy to disambiguate on).
    private static func nameTokens(_ s: String) -> [String] {
        s.unicodeScalars
            .map { scalar -> Character in
                CharacterSet.letters.contains(scalar) || scalar == " "
                    ? Character(scalar)
                    : " "
            }
            .reduce(into: "") { $0.append($1) }
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    /// Get the contact's photo data. Pure cache lookup — the thumbnail
    /// was prefetched during `reload()`, so this never blocks the main
    /// thread and is safe to call from every row render.
    func imageData(for contact: Contact) -> Data? {
        photoCache[contact.id]
    }

}
