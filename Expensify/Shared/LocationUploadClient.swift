import Foundation

/// One-shot `POST /transactions/:id/location`, with no machinery around it.
///
/// The app has `APIClient` + `HTTPClient` (retry, backoff, connection
/// recycling on network handoff), and none of that belongs in the
/// location-push extension: an extension gets a short, hard budget, and a
/// retry ladder inside it just guarantees the process is killed mid-ladder.
/// One attempt, then give up — the row stays `awaiting`, and the SLC-wake
/// backfill or the next foreground picks it up.
///
/// Compiled into both targets so there is exactly one definition of the wire
/// shape. The app keeps using `APIClient.uploadLocation`; this exists for the
/// extension.
enum LocationUploadClient {

    enum UploadError: Error {
        case badStatus(Int)
    }

    static func upload(
        transactionId: String,
        latitude: Double,
        longitude: Double,
        city: String? = nil
    ) async throws {
        struct Body: Encodable {
            let lat: Double
            let lng: Double
            let city: String?
        }

        var req = URLRequest(
            url: Constants.baseURL.appendingPathComponent("/transactions/\(transactionId)/location")
        )
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        // Shorter than URLSession's 60s default. An extension that spends 60s
        // waiting on a dead socket is an extension iOS terminates before it
        // can call its completion handler.
        req.timeoutInterval = 10
        req.httpBody = try JSONEncoder().encode(
            Body(lat: latitude, lng: longitude, city: city)
        )

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw UploadError.badStatus(http.statusCode)
        }
    }
}
