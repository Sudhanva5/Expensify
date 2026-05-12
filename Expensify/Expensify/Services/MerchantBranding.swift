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
        "Cursor": "cursor.com",
        "GitHub": "github.com",
        "Apple": "apple.com",
        "iCloud": "apple.com",
        "Notion": "notion.so",
        "Figma": "figma.com",

        // Travel
        "Ola": "olacabs.com",
        "Uber": "uber.com",
        "IRCTC": "irctc.co.in",
        "IndiGo": "goindigo.in",
        "Akasa Air": "akasaair.com",
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
        // Exact case-insensitive match wins
        if let exact = domainMap.first(where: { $0.key.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact.value
        }
        // Substring match (handle "RAZ*Swiggy", "PAYU*Netflix", etc.)
        for (key, value) in domainMap {
            if trimmed.range(of: key, options: .caseInsensitive) != nil {
                return value
            }
        }
        return nil
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
