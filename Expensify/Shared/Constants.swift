import Foundation

/// V1 hardcoded config. Replace before running on a real device.
/// Eventually these move to a build-config xcconfig (one set for sandbox APNs,
/// one for production), but for personal-use V1 a single source of truth is fine.
// nonisolated so the APIClient actor (off main) can read these without an
// async hop. Both values are immutable `let`s — safe to share across actors.
nonisolated enum Constants {
    /// Production URL of the backend.
    ///
    /// The route goes through a Cloudflare Worker that reverse-proxies
    /// the Railway backend. Why:
    ///
    ///   1. Indian carriers (Jio / Airtel / VI) silently DNS-filter the
    ///      entire `*.up.railway.app` TLD as part of "safe browsing"
    ///      rules. Direct calls fail on cellular.
    ///   2. Our custom Cloudflare-proxied domain
    ///      (`expensify.sudhanva.space`) bypassed (1) for a while, but
    ///      Jio's DPI started throttling it at random times.
    ///   3. A Worker on `*.workers.dev` lives on a different anycast IP
    ///      pool AND the Host header is shared with millions of CF
    ///      customers — Jio can't single it out without breaking a huge
    ///      chunk of the internet.
    ///
    /// Worker source: `cloudflare-worker/src/index.ts` — replays method /
    /// headers / body verbatim against the Railway origin, so every
    /// endpoint works transparently.
    static let baseURL: URL = URL(string: "https://expensify-proxy.sudhanva-udupi55.workers.dev")!

    /// Static API token shared between iOS and backend. Generate any random
    /// 32+ char string. Set the *same* value on Railway as `API_TOKEN`.
    /// In production you'd put this in Keychain; for V1 it sits here so you
    /// can swap it without touching every call site.
    static let apiToken: String = "55fc5bb59b40e6ec8d7d808787726c692a1ee8840b9a796596a85b801878afaa"
}
