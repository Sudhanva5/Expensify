import Foundation

/// Wire-format mirror of what `GET /transactions` returns. Snake-case fields
/// are mapped via JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase.
/// Conversion to the strongly-typed `Transaction` happens in `toModel()`.
struct TransactionDTO: Codable {
    let id: String
    let amountInrMinor: Int64
    let currency: String
    let merchantRaw: String
    let merchantNormalized: String
    let vpa: String?
    let direction: String
    let instrument: String
    let occurredAt: String        // ISO 8601
    let category: String?         // category name, e.g. "Food"
    let confidence: Double?
    let signalSource: String?
    let status: String
    let locationLat: Double?
    let locationLng: Double?
    let locationStatus: String

    func toModel() -> Transaction? {
        let dir: Transaction.Direction
        switch direction {
        case "in": dir = .in
        case "out": dir = .out
        default: return nil
        }

        let txStatus: Transaction.Status
        switch status {
        case "awaiting_location": txStatus = .awaitingLocation
        case "pending_review": txStatus = .pendingReview
        case "resolved": txStatus = .resolved
        default: return nil
        }

        let locStatus: Transaction.LocationStatus
        switch locationStatus {
        case "awaiting": locStatus = .awaiting
        case "fulfilled": locStatus = .fulfilled
        case "missed": locStatus = .missed
        case "not_applicable": locStatus = .notApplicable
        default: locStatus = .notApplicable
        }

        let signal: Transaction.SignalSource?
        if let s = signalSource {
            signal = Transaction.SignalSource(rawValue: s)
        } else {
            signal = nil
        }

        let cat: Category?
        if let name = category {
            cat = Category(rawValue: name)
        } else {
            cat = nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let occurred = formatter.date(from: occurredAt)
            ?? ISO8601DateFormatter().date(from: occurredAt)
            ?? Date()

        return Transaction(
            id: id,
            amountInr: Decimal(amountInrMinor) / 100,
            currency: currency,
            merchantRaw: merchantRaw,
            merchantNormalized: merchantNormalized,
            vpa: vpa,
            direction: dir,
            instrument: instrument,
            occurredAt: occurred,
            category: cat,
            confidence: confidence,
            signalSource: signal,
            status: txStatus,
            locationLat: locationLat,
            locationLng: locationLng,
            locationCity: nil,
            locationStatus: locStatus
        )
    }
}
