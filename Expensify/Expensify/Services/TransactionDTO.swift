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
    /// Optional receipt info (from /receipts pipeline). Backend returns
    /// `null` when no receipt has been bound to this transaction yet.
    let receipt: ReceiptDTO?
    /// Optional list of nearby Places candidates persisted at recategorize
    /// time, surfaced as suggestions when no auto-tag was possible.
    let placesSuggestions: [PlaceSuggestionDTO]?
    /// Freeform user note. Null when unset.
    let notes: String?

    struct PlaceSuggestionDTO: Codable {
        let name: String
        let category: String
        let distanceM: Int
        let lat: Double?
        let lng: Double?
        let formattedAddress: String?
    }

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
            locationStatus: locStatus,
            receipt: receipt?.toModel(),
            placesSuggestions: placesSuggestions?.map {
                PlaceSuggestion(
                    name: $0.name,
                    category: $0.category,
                    distanceM: $0.distanceM,
                    lat: $0.lat,
                    lng: $0.lng,
                    formattedAddress: $0.formattedAddress
                )
            },
            notes: notes
        )
    }
}

/// Wire shape of the receipt embedded in `GET /transactions` response.
struct ReceiptDTO: Codable {
    let id: String
    let gmailMessageId: String
    let source: String
    let subject: String
    let snippet: String
    let receivedAt: String           // ISO 8601
    let fromAddress: String?
    let amountInrMinor: Int64?
    let orderId: String?
    let items: [ItemDTO]?
    let fees: [FeeDTO]?
    let meta: MetaDTO?

    struct ItemDTO: Codable {
        let name: String
        let qty: Int
        let priceInr: Decimal
    }
    struct FeeDTO: Codable {
        let name: String
        let amountInr: Decimal
    }
    struct MetaDTO: Codable {
        let journeyFrom: EntryDTO?
        let journeyTo: EntryDTO?

        struct EntryDTO: Codable {
            let text: String
            let timestamp: String
        }
    }

    func toModel() -> ReceiptDetails {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let received = formatter.date(from: receivedAt)
            ?? ISO8601DateFormatter().date(from: receivedAt)
            ?? Date()

        return ReceiptDetails(
            id: id,
            gmailMessageId: gmailMessageId,
            source: source,
            subject: subject,
            snippet: snippet,
            receivedAt: received,
            fromAddress: fromAddress,
            amountInr: amountInrMinor.map { Decimal($0) / 100 },
            orderId: orderId,
            items: items?.map {
                ReceiptItem(name: $0.name, qty: $0.qty, priceInr: $0.priceInr)
            },
            fees: fees?.map {
                ReceiptFee(name: $0.name, amountInr: $0.amountInr)
            },
            meta: meta.map {
                ReceiptMeta(
                    journeyFrom: $0.journeyFrom.map {
                        JourneyEntry(text: $0.text, timestamp: $0.timestamp)
                    },
                    journeyTo: $0.journeyTo.map {
                        JourneyEntry(text: $0.text, timestamp: $0.timestamp)
                    }
                )
            }
        )
    }
}
