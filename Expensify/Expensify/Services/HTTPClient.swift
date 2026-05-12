import Foundation

/// App-internal HTTP client. Sits between APIClient and URLSession to add
/// behavior the rest of the app shouldn't have to know about:
///
///   • Owns a dedicated URLSession (not URLSession.shared) so we control
///     timeouts, connection caching, and lifecycle separately from the rest
///     of iOS.
///   • waitsForConnectivity = true → if the phone briefly has no signal,
///     the request queues and fires when connectivity comes back instead of
///     failing fast.
///   • Smart retry: 2 retries with exponential backoff for transient errors
///     (timeout, connection lost, DNS, 5xx). Never retries 4xx (logic /
///     auth errors don't recover by retrying).
///   • On a network-interface change (Wi-Fi ↔ cellular), invalidate the
///     URLSession so the next request opens a fresh TCP connection. Stale
///     cached connections after a handoff is the #1 cause of "the first
///     request after backgrounding fails."
///   • warmup() establishes the TCP+TLS handshake before the user's first
///     real request, so cold-start latency is invisible.
actor HTTPClient {
    static let shared = HTTPClient()

    private var session: URLSession

    init() {
        self.session = Self.makeSession()
        // Subscribe on the next runloop tick — NetworkMonitor is MainActor
        // and we can't call into it from inside an actor init synchronously.
        Task { @MainActor in
            NetworkMonitor.shared.onChange = { [weak self] in
                Task {
                    await self?.recreateSession(reason: "network changed")
                }
            }
        }
    }

    // MARK: - Public API

    /// Send a request with retry. Returns (data, http response). Caller
    /// inspects status code for 2xx vs 4xx.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var lastError: Error?

        while attempt < Self.maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HTTPClientError.invalidResponse
                }

                // Retry 5xx (Railway transient). Never retry 4xx.
                if (500...599).contains(http.statusCode) {
                    if attempt < Self.maxAttempts && Self.shouldRetry(statusCode: http.statusCode) {
                        try? await Task.sleep(nanoseconds: Self.backoffNs(attempt: attempt))
                        continue
                    }
                }

                return (data, http)
            } catch {
                lastError = error
                if attempt < Self.maxAttempts && Self.shouldRetry(error: error) {
                    try? await Task.sleep(nanoseconds: Self.backoffNs(attempt: attempt))
                    continue
                }
                throw error
            }
        }

        throw lastError ?? HTTPClientError.unknown
    }

    /// Fire a GET to the given URL as a fire-and-forget warmup. Establishes
    /// TCP+TLS to the host so the first real request feels instant.
    func warmup(baseURL: URL) {
        Task {
            var req = URLRequest(url: baseURL.appendingPathComponent("/health"))
            req.httpMethod = "GET"
            req.timeoutInterval = 5
            _ = try? await session.data(for: req)
            #if DEBUG
            print("[HTTPClient] warmup ping completed")
            #endif
        }
    }

    // MARK: - Internal

    private func recreateSession(reason: String) {
        #if DEBUG
        print("[HTTPClient] recreating session: \(reason)")
        #endif
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    // MARK: - Config

    private static let maxAttempts = 3

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        // Short per-request timeout — the user shouldn't wait a minute for
        // an error message. The resource timeout caps the overall life of
        // a request (including waiting for connectivity).
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    private static func shouldRetry(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private static func shouldRetry(statusCode: Int) -> Bool {
        // Bad gateway, service unavailable, gateway timeout — the typical
        // Railway transient errors during a deploy or brief overload.
        [502, 503, 504].contains(statusCode)
    }

    private static func backoffNs(attempt: Int) -> UInt64 {
        // 0.5s, 1.5s (only used between retries, attempt is 1-based)
        let seconds = pow(3.0, Double(attempt - 1)) * 0.5
        return UInt64(seconds * 1_000_000_000)
    }
}

enum HTTPClientError: Error, LocalizedError {
    case invalidResponse
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Server returned an invalid response"
        case .unknown: return "Unknown network error"
        }
    }
}
