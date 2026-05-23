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

        // Amazon Pay marketplace pattern: "amznpl<brand>v<digits>" where
        // <brand> is the actual merchant (e.g. `amznplpvrv2033702` →
        // PVR). Strip the rail prefix + trailing transaction id and try
        // to map the inner brand FIRST, before the generic substring
        // search would otherwise see "AMZN" and return Amazon's logo.
        // The user paid PVR; Amazon Pay was just the rail.
        if let amazonPayBrand = extractAmazonPayBrand(trimmed),
           let hit = lookupSubstring(amazonPayBrand) {
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

    /// If `merchantRaw` is an Amazon Pay marketplace string, return the
    /// inner brand identifier. Pattern: `amznpl<letters><digits-or-v>...`
    ///   • `amznplpvrv2033702`  → "pvr"     (PVR cinemas)
    ///   • `amznplbms` + suffix → "bms"     (BookMyShow)
    ///   • `amznplnykaa…`       → "nykaa"   (Nykaa)
    /// Returns nil for non-Amazon-Pay payee strings.
    private static func extractAmazonPayBrand(_ s: String) -> String? {
        let lower = s.lowercased()
        guard lower.hasPrefix("amznpl") else { return nil }
        // Step past the rail prefix and take consecutive letters.
        var brand = ""
        for ch in lower.dropFirst("amznpl".count) {
            if ch.isLetter {
                brand.append(ch)
            } else {
                break
            }
        }
        return brand.count >= 2 ? brand : nil
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
