import Foundation

/// Thin REST wrapper for the Expensify backend on Railway. All requests
/// go through HTTPClient, which owns retries, timeouts, and connection
/// lifecycle management.
actor APIClient {
    static let shared = APIClient()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Connectivity test (used by Settings → Test connection)

    struct PingResult {
        let healthOK: Bool
        let authedOK: Bool
        let healthError: String?
        let authedError: String?
    }

    /// Test both unauthenticated reachability and authenticated identity.
    /// Used by the Settings "Test connection" button. Read-only — never
    /// mutates DB rows.
    func ping() async -> PingResult {
        var healthOK = false
        var healthErr: String? = nil
        do {
            let _: EmptyAck = try await getJSONNoAuth(path: "/health")
            healthOK = true
        } catch {
            healthErr = error.localizedDescription
        }

        var authedOK = false
        var authedErr: String? = nil
        do {
            let _: EmptyAck = try await getJSON(path: "/transactions/auth/check")
            authedOK = true
        } catch {
            authedErr = error.localizedDescription
        }

        return PingResult(
            healthOK: healthOK,
            authedOK: authedOK,
            healthError: healthErr,
            authedError: authedErr
        )
    }

    private struct EmptyAck: Decodable { let ok: Bool? }

    // MARK: - Transactions

    /// Fetch the most recent transactions for the iOS UI.
    func fetchTransactions(limit: Int = 100) async throws -> [Transaction] {
        struct Wire: Decodable {}
        var components = URLComponents(
            url: Constants.baseURL.appendingPathComponent("/transactions/"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw APIError.invalidResponse }

        let (data, http) = try await get(url: url)
        try ensure2xx(http: http, data: data)

        let dtos = try decoder.decode([TransactionDTO].self, from: data)
        return dtos.compactMap { $0.toModel() }
    }

    /// Mark a transaction as resolved. Optionally override the category at
    /// the same time (used by the post-swipe tagging list).
    func confirmTransaction(id: String, overrideCategory: Category? = nil) async throws {
        struct Body: Encodable {
            let category: String?
            let status: String
        }
        let body = Body(category: overrideCategory?.rawValue, status: "resolved")
        try await patchNoContent(path: "/transactions/\(id)", body: body)
    }

    /// Transactions whose location is still awaiting upload from iOS, with
    /// their original `occurredAt`. The backfill flow uses occurredAt to
    /// pick the location-history entry closest in time to when each
    /// transaction actually happened.
    func fetchAwaitingLocationTransactions() async throws -> [AwaitingTransaction] {
        struct Row: Decodable {
            let id: String
            let occurredAt: String
        }
        let rows: [Row] = try await getJSON(path: "/transactions/awaiting")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        return rows.compactMap { row in
            let date = formatter.date(from: row.occurredAt) ?? fallback.date(from: row.occurredAt)
            guard let date else { return nil }
            return AwaitingTransaction(id: row.id, occurredAt: date)
        }
    }

    struct AwaitingTransaction: Hashable, Sendable {
        let id: String
        let occurredAt: Date
    }

    // MARK: - Device + location

    /// Tell the backend about this device's APNs token so it can send silent pushes.
    func registerDevice(apnsToken: String) async throws {
        struct Body: Encodable { let apnsToken: String }
        try await postNoContent(path: "/devices/register", body: Body(apnsToken: apnsToken))
    }

    /// Upload the captured GPS for a transaction.
    func uploadLocation(
        transactionId: String,
        latitude: Double,
        longitude: Double,
        city: String?
    ) async throws {
        struct Body: Encodable {
            let lat: Double
            let lng: Double
            let city: String?
        }
        try await postNoContent(
            path: "/transactions/\(transactionId)/location",
            body: Body(lat: latitude, lng: longitude, city: city)
        )
    }

    // MARK: - Internals

    private func getJSON<T: Decodable>(path: String) async throws -> T {
        let url = Constants.baseURL.appendingPathComponent(path)
        let (data, http) = try await get(url: url, authed: true)
        try ensure2xx(http: http, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func getJSONNoAuth<T: Decodable>(path: String) async throws -> T {
        let url = Constants.baseURL.appendingPathComponent(path)
        let (data, http) = try await get(url: url, authed: false)
        try ensure2xx(http: http, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func get(url: URL, authed: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if authed {
            req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        }
        return try await HTTPClient.shared.send(req)
    }

    private func patchNoContent<B: Encodable>(path: String, body: B) async throws {
        try await sendNoContent(method: "PATCH", path: path, body: body)
    }

    private func postNoContent<B: Encodable>(path: String, body: B) async throws {
        try await sendNoContent(method: "POST", path: path, body: body)
    }

    private func sendNoContent<B: Encodable>(method: String, path: String, body: B) async throws {
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try encoder.encode(body)

        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)
    }

    private func ensure2xx(http: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpStatus(http.statusCode, body: body)
        }
    }
}

enum APIError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid HTTP response from backend"
        case .httpStatus(let code, let body):
            return "Server returned \(code): \(body)"
        }
    }
}
