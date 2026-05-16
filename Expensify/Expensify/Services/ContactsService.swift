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

    /// Diagnostic counts, surfaced via `diagnostics` for in-app debugging.
    /// Updated on every reload(). Lets the user see if photo prefetch is
    /// actually populating cache without needing Xcode console.
    var diagnostics: Diagnostics = .empty

    struct Diagnostics: Equatable {
        let contactCount: Int
        let phonesIndexed: Int
        let photosCached: Int
        let photosFromThumb: Int
        let photosFromFull: Int
        let flagSaysAvailable: Int

        static let empty = Diagnostics(
            contactCount: 0, phonesIndexed: 0, photosCached: 0,
            photosFromThumb: 0, photosFromFull: 0, flagSaysAvailable: 0
        )

        var summary: String {
            "\(contactCount) contacts · \(photosCached) photos (\(photosFromThumb) thumb + \(photosFromFull) full) · flag claimed \(flagSaysAvailable)"
        }
    }

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

    /// Photo bytes for Google-contact matches, keyed by the transaction's
    /// VPA. Populated by `fetchGooglePhotoIfNeeded(for:)` when the local
    /// CNContactStore has no entry (or no photo) — the GPay-style "I
    /// know who you're paying because you share an email account with
    /// them" lookup. Persisted only in memory for now.
    private var googlePhotoByVpa: [String: Data] = [:]
    /// VPAs we've already asked the backend about and got "no match" or
    /// "no photo" — short-circuits re-fetches on every redraw.
    private var googleNotFoundVpas: Set<String> = []
    /// VPAs with an in-flight network request, so onAppear in 50 rows
    /// doesn't fan out into 50 duplicate fetches for the same payee.
    private var googleInflight: Set<String> = []
    /// Display name returned by Google for the VPA (used by detail sheet).
    private var googleNameByVpa: [String: String] = [:]

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
                    let flagSaysAvailable = cn.imageDataAvailable
                    let c = Contact(
                        id: cn.identifier,
                        displayName: display,
                        givenName: cn.givenName,
                        familyName: cn.familyName,
                        phoneNumbers: phones,
                        hasPhoto: flagSaysAvailable
                    )
                    fetched.append(c)
                    cnById[cn.identifier] = cn
                    // ALWAYS try to grab photo data regardless of the
                    // imageDataAvailable flag — that flag has been seen to
                    // return false for iCloud-synced contacts whose photos
                    // ARE reachable via thumbnailImageData / imageData.
                    // Trust the data, not the flag.
                    if flagSaysAvailable { photoStats.available += 1 }
                    if let data = cn.thumbnailImageData {
                        photos[cn.identifier] = data
                        photoStats.withThumb += 1
                    } else if let data = cn.imageData {
                        // Fall back to full image when no thumbnail exists.
                        // iOS downsamples at render time.
                        photos[cn.identifier] = data
                        photoStats.withFull += 1
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
                let phoneIndex = Self.buildPhoneIndex(from: fetched)
                self.indexByPhone = phoneIndex
                self.photoCache = photos
                self.diagnostics = Diagnostics(
                    contactCount: fetched.count,
                    phonesIndexed: phoneIndex.count,
                    photosCached: photos.count,
                    photosFromThumb: photoStats.withThumb,
                    photosFromFull: photoStats.withFull,
                    flagSaysAvailable: photoStats.available
                )
                #if DEBUG
                print("[ContactsService] indexed \(fetched.count) contacts; photos: \(photos.count) cached (\(photoStats.withThumb) thumb + \(photoStats.withFull) full); flag-said-available: \(photoStats.available)")
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

    /// Returns the contact a transaction was sent to. Two-pass match:
    ///
    ///   1. **Phone match** (highest confidence): VPA's local part parses
    ///      as a 10-digit phone number that lives in the address book.
    ///
    ///   2. **Token-score name match** (medium confidence): pulls name
    ///      tokens from BOTH the bank payee (`merchantRaw`) AND the VPA
    ///      local-part (so `s.neha2003rajesh@okhdfcbank` contributes
    ///      "sneha" and "rajesh" beyond what the bank's truncated "SNEHA
    ///      R" gives us). Scores each contact by how many of those
    ///      tokens appear in their display name. The winner only
    ///      matches when EITHER (a) score ≥ 2 with a unique top
    ///      candidate, OR (b) score == 1 and that token is uniquely
    ///      associated with a single contact in the address book.
    ///      Returning nil on ambiguity is intentional — it's what
    ///      stopped the "Sneha Bubbly → Sneha Appa" false-positive.
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

        // --- Pass 2: token-score name match ------------------------------
        // Union of tokens from the bank payee AND the VPA local-part.
        // VPA local often carries the FULL name even when the bank
        // truncated to "SNEHA R" — e.g. `s.neha2003rajesh@okhdfcbank`
        // gives us "rajesh" too, which uniquely disambiguates.
        var payeeTokens = Set(Self.nameTokens(transaction.merchantRaw))
        if let vpa = transaction.vpa {
            let at = vpa.firstIndex(of: "@") ?? vpa.endIndex
            let local = String(vpa[..<at])
            payeeTokens.formUnion(Self.nameTokens(local))
        }
        guard !payeeTokens.isEmpty else { return nil }

        // Score every contact by token overlap with the union set.
        var bestScore = 0
        var topCandidates: [Contact] = []
        for contact in allContacts {
            let contactTokens = Set(Self.nameTokens(contact.displayName))
            let overlap = payeeTokens.intersection(contactTokens).count
            if overlap == 0 { continue }
            if overlap > bestScore {
                bestScore = overlap
                topCandidates = [contact]
            } else if overlap == bestScore {
                topCandidates.append(contact)
            }
        }

        if bestScore == 0 { return nil }

        // Multi-token unique top → safe match.
        if bestScore >= 2 && topCandidates.count == 1 {
            return topCandidates[0]
        }

        // Single-token best-overlap → only accept when the ONE matching
        // token uniquely identifies a single contact across the whole
        // address book. Otherwise it's ambiguous (e.g. multiple Snehas).
        if bestScore == 1 && topCandidates.count == 1 {
            return topCandidates[0]
        }

        return nil
    }

    /// Normalize a name-ish string into its meaningful tokens. Strips
    /// non-letter characters (digits, punctuation), lowercases, and
    /// drops single-letter tokens because initials like "R" / "S" are
    /// too noisy to disambiguate on. Used for BOTH contact display
    /// names AND VPA local-parts.
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

    /// True if a given contact has cached photo data. Used by the
    /// Settings → Contacts match-preview to show "📷 yes" / "—" badges
    /// so the user can tell why a row's avatar is initials vs. photo.
    func hasCachedPhoto(_ contact: Contact) -> Bool {
        photoCache[contact.id] != nil
    }

    // MARK: - Google contacts fallback

    /// In-memory Google photo bytes for a given VPA, if previously fetched.
    func googlePhotoData(for vpa: String) -> Data? { googlePhotoByVpa[vpa] }

    /// Cached Google display name for a VPA — used by detail sheets to
    /// surface "actually this VPA belongs to your contact 'Rapido —
    /// Bengaluru Bike'" even when the local address book had nothing.
    func googleDisplayName(for vpa: String) -> String? { googleNameByVpa[vpa] }

    /// Best photo for this transaction across both caches:
    ///   1. Local CN contact match (already tried by call sites today)
    ///   2. Google contacts match keyed by VPA
    /// Returns nil when neither has a photo so callers can stay on the
    /// favicon/initials fallback.
    func bestPhotoData(for tx: Transaction) -> Data? {
        if let c = match(for: tx), let img = imageData(for: c) {
            return img
        }
        if let vpa = tx.vpa, let img = googlePhotoByVpa[vpa] {
            return img
        }
        return nil
    }

    /// Best display name for a transaction across both caches. Mirrors
    /// `bestPhotoData(for:)` so views can pick a name + photo in one
    /// consistent call.
    func bestContactName(for tx: Transaction) -> String? {
        if let c = match(for: tx) { return c.displayName }
        if let vpa = tx.vpa, let name = googleNameByVpa[vpa] { return name }
        return nil
    }

    /// Hit `/contacts/google-lookup` for the transaction's VPA and cache
    /// the photo bytes if Google returns one. Idempotent — repeat calls
    /// for the same VPA short-circuit on the in-flight or 'not found'
    /// sets. Safe to call from row onAppear; the request is debounced
    /// per VPA.
    func fetchGooglePhotoIfNeeded(for tx: Transaction) async {
        guard tx.direction == .out else { return }
        guard let vpa = tx.vpa, !vpa.isEmpty else { return }
        if googlePhotoByVpa[vpa] != nil { return }
        if googleNotFoundVpas.contains(vpa) { return }
        if googleInflight.contains(vpa) { return }
        // Skip if we already have a local CN contact with a photo —
        // the local one wins and Google would be redundant.
        if let local = match(for: tx), photoCache[local.id] != nil { return }

        googleInflight.insert(vpa)
        defer { googleInflight.remove(vpa) }

        do {
            let result = try await APIClient.shared.googleContactLookup(
                vpa: vpa,
                merchantRaw: tx.merchantRaw
            )
            guard let result, let urlString = result.photoUrl, let url = URL(string: urlString) else {
                googleNotFoundVpas.insert(vpa)
                if let displayName = result?.displayName {
                    googleNameByVpa[vpa] = displayName
                }
                return
            }
            // People-API photo URLs are public-ish but lifetime-bounded;
            // pull the bytes through our own URLSession so the avatar
            // doesn't try to fetch a URL that expires between renders.
            let (data, _) = try await URLSession.shared.data(from: url)
            googlePhotoByVpa[vpa] = data
            if let displayName = result.displayName {
                googleNameByVpa[vpa] = displayName
            }
        } catch {
            // Soft-fail: mark not-found so we don't retry every redraw.
            // The user can still see the initials avatar; no degradation.
            googleNotFoundVpas.insert(vpa)
            #if DEBUG
            print("[ContactsService] google lookup failed for \(vpa): \(error.localizedDescription)")
            #endif
        }
    }

}
