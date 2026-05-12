import Foundation

/// Tiny HTTP client for the iOS app to talk to the Railway backend.
/// One actor instance, shared. All calls require the static API_TOKEN.
actor APIClient {
    static let shared = APIClient()

    private let session: URLSession = .shared
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    // MARK: - Public

    /// Result of a connectivity test.
    struct PingResult {
        let healthOK: Bool          // GET /health unauthenticated
        let authedOK: Bool          // POST /devices/register with a dummy token
        let healthError: String?
        let authedError: String?
    }

    /// Hit /health (unauthenticated) to verify the network path, then a
    /// read-only authenticated call to verify API_TOKEN matches between this
    /// build and the backend env. Both checks are best-effort. Neither writes.
    func ping() async -> PingResult {
        let healthURL = Constants.baseURL.appendingPathComponent("/health")
        var healthOK = false
        var healthErr: String? = nil
        do {
            let (data, response) = try await session.data(from: healthURL)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                healthOK = true
            } else if let http = response as? HTTPURLResponse {
                healthErr = "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")"
            } else {
                healthErr = "non-HTTP response"
            }
        } catch {
            healthErr = error.localizedDescription
        }

        // Auth test: read-only check. Won't mutate the DB.
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

    /// Fetch the most recent transactions for the iOS UI.
    func fetchTransactions(limit: Int = 100) async throws -> [Transaction] {
        var components = URLComponents(
            url: Constants.baseURL.appendingPathComponent("/transactions/"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw APIError.invalidResponse }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let dtos = try decoder.decode([TransactionDTO].self, from: data)
        return dtos.compactMap { $0.toModel() }
    }

    /// Mark a transaction as resolved. Optionally override the category at
    /// the same time (used by the post-swipe tagging list). Called from the
    /// Activity tab on swipe-right and on "Update Changes".
    func confirmTransaction(id: String, overrideCategory: Category? = nil) async throws {
        struct Body: Encodable {
            let category: String?
            let status: String
        }
        // category is Optional<String>; Swift's JSONEncoder OMITS nil fields
        // by default, so omitting the override produces `{"status":"resolved"}`
        // which leaves the existing category alone.
        let body = Body(category: overrideCategory?.rawValue, status: "resolved")
        try await patchNoContent(path: "/transactions/\(id)", body: body)
    }

    /// IDs of transactions whose location is still awaiting upload from iOS.
    /// Called when SLC fires or the app foregrounds — backfill those rows
    /// with the device's best-known location.
    func fetchAwaitingLocationTransactionIds() async throws -> [String] {
        struct Row: Decodable { let id: String }
        let rows: [Row] = try await getJSON(path: "/transactions/awaiting")
        return rows.map(\.id)
    }

    /// Tell the backend about this device's APNs token so it can send silent pushes.
    func registerDevice(apnsToken: String) async throws {
        struct Body: Encodable { let apnsToken: String }
        try await postNoContent(path: "/devices/register", body: Body(apnsToken: apnsToken))
    }

    /// Upload the captured GPS for a transaction. Called from the silent-push handler.
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

    // MARK: - Private

    private func getJSON<T: Decodable>(path: String) async throws -> T {
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpStatus(http.statusCode, body: body)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
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
        // Keep snake_case keys to match the backend's expected payload shape
        // (the encoder converts camelCase -> snake_case automatically).
        req.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
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
            return "Backend returned \(code): \(body)"
        }
    }
}
