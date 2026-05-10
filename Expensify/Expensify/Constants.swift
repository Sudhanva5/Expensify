import Foundation

/// V1 hardcoded config. Replace before running on a real device.
/// Eventually these move to a build-config xcconfig (one set for sandbox APNs,
/// one for production), but for personal-use V1 a single source of truth is fine.
enum Constants {
    /// Railway production URL of the backend.
    static let baseURL: URL = URL(string: "https://expensify-production.up.railway.app")!

    /// Static API token shared between iOS and backend. Generate any random
    /// 32+ char string. Set the *same* value on Railway as `API_TOKEN`.
    /// In production you'd put this in Keychain; for V1 it sits here so you
    /// can swap it without touching every call site.
    static let apiToken: String = "REPLACE_ME_WITH_RANDOM_32CHAR_STRING"
}
