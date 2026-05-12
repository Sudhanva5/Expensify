import Foundation

/// V1 hardcoded config. Replace before running on a real device.
/// Eventually these move to a build-config xcconfig (one set for sandbox APNs,
/// one for production), but for personal-use V1 a single source of truth is fine.
// nonisolated so the APIClient actor (off main) can read these without an
// async hop. Both values are immutable `let`s — safe to share across actors.
nonisolated enum Constants {
    /// Railway production URL of the backend.
    static let baseURL: URL = URL(string: "https://expensify-production.up.railway.app")!

    /// Static API token shared between iOS and backend. Generate any random
    /// 32+ char string. Set the *same* value on Railway as `API_TOKEN`.
    /// In production you'd put this in Keychain; for V1 it sits here so you
    /// can swap it without touching every call site.
    static let apiToken: String = "55fc5bb59b40e6ec8d7d808787726c692a1ee8840b9a796596a85b801878afaa"
}
