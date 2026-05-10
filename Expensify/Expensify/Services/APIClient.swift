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

    private func postNoContent<B: Encodable>(path: String, body: B) async throws {
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
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
