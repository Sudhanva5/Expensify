import Foundation
import Contacts
import Observation

/// Local-only contact matcher. Reads the user's Contacts on demand, builds
/// an index of "normalized phone number" → contact, and answers one
/// question for the rest of the app:
///
///   `match(for transaction:)` — was this UPI transaction sent to a phone
///   number that lives in your address book? When the VPA carries an
///   embedded phone (`9876543210@ybl`) and that phone matches a contact,
///   the iOS app overlays the contact's display name + photo onto the
///   row AND force-tags the category as P2P.
///
/// Matching is **strictly by phone number** — name matching was disabled
/// after producing false positives (e.g. "Sneha Bubbly" matching "Sneha
/// Appa" because they share a given name). VPAs whose local-part is a
/// handle (`sneha.r@oksbi`) don't yield a match here; those land in the
/// review queue or default merchant pipeline instead.
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
                self.indexByPhone = Self.buildPhoneIndex(from: fetched)
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

    /// Returns the contact a transaction was sent to, matched by **phone
    /// number embedded in the VPA**. Phone is the only truly unique field;
    /// name-based matching gave us false positives like "Sneha Bubbly"
    /// matching to "Sneha Appa" because they share a given name.
    ///
    /// Only matches when:
    ///   - direction = out (it's an outbound payment)
    ///   - instrument starts with "account_" (UPI from your bank, not card)
    ///   - the VPA's local part parses as a 10-digit phone number
    ///   - some contact in the address book has that same number
    ///
    /// Returns nil for transactions whose VPA local-part is a name handle
    /// (`sneha.r@oksbi`, `bob.smith@axl`). Those land in the review queue
    /// or default merchant pipeline — no risky fuzzy-name match.
    func match(for transaction: Transaction) -> Contact? {
        guard transaction.direction == .out else { return nil }
        guard transaction.instrument.hasPrefix("account_") else { return nil }
        guard let vpa = transaction.vpa, !vpa.isEmpty else { return nil }
        guard let phone = Self.phoneFromVpa(vpa) else { return nil }
        guard let candidates = indexByPhone[phone], !candidates.isEmpty else {
            return nil
        }
        // Phone numbers are unique — there should only ever be one contact
        // per number. If duplicates exist, take the first; the user can
        // clean up their address book.
        return candidates[0]
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

}
