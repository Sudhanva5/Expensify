import Foundation

/// Resolves a merchant name to:
///   • A domain → favicon URL (Google's free favicon service, no API key)
///   • Otherwise, a clean two-character initial set for the avatar
///
/// Lookup strategy:
///   1. Exact case-insensitive match against the curated `domainMap`
///   2. Substring match (so "RAZ*Swiggy" still resolves to Swiggy)
///   3. Fall through to initials
///
/// The map is intentionally small and hand-curated — better to have 30
/// merchants render with sharp brand identity than 1000 with sketchy logos.
enum MerchantBranding {
    static let domainMap: [String: String] = [
        // Food
        "Swiggy": "swiggy.com",
        "Zomato": "zomato.com",
        "EatFit": "cult.fit",
        "Cult.fit": "cult.fit",
        "BUNDL TECHNOLOGIES": "swiggy.com",

        // Subscriptions
        "Netflix": "netflix.com",
        "Spotify": "spotify.com",
        "Anthropic": "anthropic.com",
        "Claude": "anthropic.com",
        "Claude.ai": "anthropic.com",
        "OpenAI": "openai.com",
        "ChatGPT": "openai.com",
        "YouTube": "youtube.com",
        // Google products — Google's favicon service only resolves real
        // hostnames, so "Google Cloud" alone never matched. Map the
        // common Google-* SaaS names back to google.com (close enough —
        // they all share the same favicon).
        "Google": "google.com",
        "Google Cloud": "cloud.google.com",
        "Google Cloud Platform": "cloud.google.com",
        "GCP": "cloud.google.com",
        "Google Workspace": "workspace.google.com",
        "Google One": "one.google.com",
        "Google Drive": "drive.google.com",
        "YouTube Premium": "youtube.com",
        "YouTube Music": "music.youtube.com",
        "Gemini": "gemini.google.com",
        "Google AI": "ai.google.com",
        "Firebase": "firebase.google.com",
        "Cursor": "cursor.com",
        "GitHub": "github.com",
        "Apple": "apple.com",
        "iCloud": "apple.com",
        "Notion": "notion.so",
        "Figma": "figma.com",

        // Travel
        "Ola": "olacabs.com",
        "Uber": "uber.com",
        "Rapido": "rapido.bike",
        "IRCTC": "irctc.co.in",
        "IndiGo": "goindigo.in",
        "Akasa Air": "akasaair.com",
        "Vistara": "airvistara.com",
        "SpiceJet": "spicejet.com",
        "Air India": "airindia.com",
        "MakeMyTrip": "makemytrip.com",
        "Goibibo": "goibibo.com",
        "Cleartrip": "cleartrip.com",
        "EaseMyTrip": "easemytrip.com",
        "RedBus": "redbus.in",
        "redBus": "redbus.in",
        "Royal Rich India (Bus)": "redbus.in",
        "KSRTC": "ksrtcblr.com",
        "APSRTC": "apsrtconline.in",
        "TSRTC": "tsrtconline.in",
        "Railway": "indianrailways.gov.in",
        "Airbnb": "airbnb.com",

        // Entertainment
        "BookMyShow": "bookmyshow.com",
        "PVR": "pvrcinemas.com",
        "INOX": "inoxmovies.com",

        // Groceries
        "BigBasket": "bigbasket.com",
        "Blinkit": "blinkit.com",
        "Zepto": "zeptonow.com",
        "Swiggy Instamart": "swiggy.com",
        "Instamart": "swiggy.com",
        "DMart": "dmart.in",

        // Amazon — bank statements use a bunch of slightly different
        // legal-entity names depending on whether it's Prime, Pay,
        // Marketplace, or the seller-services subsidiary. All of them
        // are owned by Amazon and visually want the same logo.
        "Amazon": "amazon.in",
        "Amazon.in": "amazon.in",
        "Amazon Pay": "amazon.in",
        "Amazon Prime": "primevideo.com",
        "Prime Video": "primevideo.com",
        "AMZN": "amazon.in",
        "Amazon Seller Services": "amazon.in",
        "AMAZON SELLER SERVICES": "amazon.in",
        "Amazon Web Services": "aws.amazon.com",
        "AWS": "aws.amazon.com",

        // Bank / Finance
        "HDFC": "hdfcbank.com",
        "HDFC Bank": "hdfcbank.com",
        "Zerodha": "zerodha.com",
        "Groww": "groww.in",

        // Shopping & lifestyle — brands the inner-brand extractor will
        // expose once we strip transaction IDs and corporate suffixes
        // from the bank's payee text.
        "The Souled Store": "thesouledstore.com",
        "thesouledstore": "thesouledstore.com",
        "Nykaa": "nykaa.com",
        "Mamaearth": "mamaearth.in",
        "boAt": "boat-lifestyle.com",
        "Boat Lifestyle": "boat-lifestyle.com",
        "Lenskart": "lenskart.com",
        "FirstCry": "firstcry.com",
        "Meesho": "meesho.com",
        "Ajio": "ajio.com",
        "Tata Cliq": "tatacliq.com",
        "Vyapar": "vyaparapp.in",
    ]

    /// Look up a merchant name and return the favicon URL if we recognize it.
    static func faviconURL(for merchantName: String, size: Int = 128) -> URL? {
        guard let domain = domain(for: merchantName) else { return nil }
        return URL(
            string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=\(size)"
        )
    }

    /// Domain for a merchant name, if we have one mapped.
    static func domain(for merchantName: String) -> String? {
        let trimmed = merchantName.trimmingCharacters(in: .whitespaces)
        // Exact case-insensitive match wins.
        if let exact = domainMap.first(where: { $0.key.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact.value
        }

        // Cleanup pass: payment-rail prefixes + trailing transaction IDs
        // + boilerplate corporate suffixes ("Pvt Ltd", "Services", …)
        // hide the actual brand. Strip them, try the lookup, then fall
        // through to the raw string if nothing matched.
        //
        // Examples:
        //   amznplpvrv2033702              → "pvrv"        → matches PVR
        //   thesouledstorepvtltd.63483118  → "thesouledstore" → match if mapped
        //   nykaaorder123                  → "nykaaorder"  → matches Nykaa
        //   PAYU*Google Cloud Platform Charge (already pre-stripped by backend)
        if let cleaned = extractInnerBrand(trimmed),
           cleaned.caseInsensitiveCompare(trimmed) != .orderedSame,
           let hit = lookupSubstring(cleaned) {
            return hit
        }

        // Substring match — prefer the LONGEST matching key. Otherwise
        // "Google" would beat "Google Cloud" on input like
        // "PAYU*Google Cloud Platform Charge", giving the wrong favicon.
        return lookupSubstring(trimmed)
    }

    /// Longest-key-wins substring search through the brand map.
    private static func lookupSubstring(_ haystack: String) -> String? {
        let sortedKeys = domainMap.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            if haystack.range(of: key, options: .caseInsensitive) != nil {
                return domainMap[key]
            }
        }
        return nil
    }

    /// Known payment-rail prefixes that bury the actual merchant. Backend
    /// `stripRoutingPrefix` already removes the asterisk-separated forms
    /// (`RAZ*`, `PAYU*`, …) before they reach iOS, so these are the
    /// alphanumeric-glued variants the backend can't easily detect.
    private static let railPrefixes = [
        "amznpl",   // Amazon Pay marketplace: amznpl<brand>v<id>
        "gpay-",    // Google Pay marketplace: gpay-<brand>-<id>
        "gpay.",
        "paytm-",   // Paytm wallet marketplace
        "paytm.",
        "mobikwik-",
        "phonepe-",
        "php-",     // PHP* rail (e.g. "PHP*REDBUS" — though backend often strips)
        "php.",
        "yespay-",
    ]

    /// Boilerplate corporate suffix tokens to peel off so the brand
    /// shines through. e.g. "thesouledstorepvtltd" → "thesouledstore".
    private static let corporateSuffixes = [
        "privatelimited", "pvtltd", "pvt", "ltd",
        "limited", "incorporation", "incorporated", "inc",
        "company", "co", "corporation", "corp",
        "services", "service", "enterprises", "enterprise",
        "india", "industries", "industry",
    ]

    /// Cleanup pipeline:
    ///   1. lowercase
    ///   2. drop everything after the LAST separator (`.`, `_`, `*`) — those
    ///      almost always front transaction IDs
    ///   3. strip a leading rail prefix if one matches
    ///   4. strip the trailing digit run (`nykaaorder123` → `nykaaorder`)
    ///   5. peel off a corporate boilerplate suffix (`pvtltd`, `services`, …)
    /// Returns nil if cleanup left less than 3 chars (too short to look up
    /// without false-positives).
    private static func extractInnerBrand(_ raw: String) -> String? {
        var s = raw.lowercased()

        // Step 2: everything before the last `.`/`_`/`*` separator. Picks
        // up `<brand>.<txnid>` and `<brand>_<txnid>`. We only chop when
        // the suffix is digit-heavy to avoid breaking "amazon.in" etc.
        for sep in [".", "_", "*"] {
            if let r = s.range(of: sep, options: .backwards) {
                let head = String(s[..<r.lowerBound])
                let tail = String(s[r.upperBound...])
                let tailDigits = tail.filter { $0.isNumber }.count
                if tail.count > 0 && tailDigits >= tail.count / 2 {
                    s = head
                }
            }
        }

        // Step 3: rail prefix
        for prefix in railPrefixes {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }

        // Step 4: drop trailing digits (and any single trailing 'v' from
        // version markers like "pvrv2033702" → after step pre-cleanup
        // would already be "pvrv"; keep the v but ensure trailing
        // non-letter runs are gone).
        while let last = s.last, !last.isLetter {
            s.removeLast()
        }
        // Now scan from the right: drop trailing digit runs.
        // (After the loop above s ends in a letter, so the only digits
        // left are in the middle — handled by the substring lookup.)

        // Step 5: peel one corporate suffix.
        for suffix in corporateSuffixes {
            if s.hasSuffix(suffix) && s.count > suffix.count + 2 {
                s = String(s.dropLast(suffix.count))
                break
            }
        }

        return s.count >= 3 ? s : nil
    }

    /// Two-character initials for the merchant avatar fallback.
    /// "SNEHA R" → "SN"
    /// "Sri Guru Raghavendra Enterprises" → "SR"
    /// "BIVEK DEB" → "BD"
    /// Single-word names → first two letters: "Anthropic" → "AN"
    static func initials(for merchantName: String) -> String {
        let cleaned = merchantName
            .components(separatedBy: CharacterSet(charactersIn: "*"))
            .last ?? merchantName
        let words = cleaned
            .split(separator: " ")
            .filter { !$0.isEmpty }

        if words.count >= 2 {
            let first = words[0].first.map { String($0) } ?? ""
            let second = words[1].first.map { String($0) } ?? ""
            return (first + second).uppercased()
        }

        if let only = words.first {
            let firstTwo = only.prefix(2)
            return String(firstTwo).uppercased()
        }

        return "•"
    }
}
