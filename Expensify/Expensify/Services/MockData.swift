import Foundation

/// Static mock data used to drive the UI before the Railway backend is wired up.
/// Mirrors the kind of rows we expect to see from real HDFC traffic, so what
/// you see in the simulator now is faithful to what the live app will show.
enum MockData {
    static let transactions: [Transaction] = {
        let cal = Calendar.current
        let now = Date()
        let day = { (offset: Int, hour: Int, minute: Int) -> Date in
            let base = cal.date(byAdding: .day, value: -offset, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }

        return [
            Transaction(
                id: "tx_001",
                amountInr: 547.00,
                currency: "INR",
                merchantRaw: "BUNDL TECHNOLOGIES",
                merchantNormalized: "Swiggy",
                vpa: nil,
                direction: .out,
                instrument: "card_3328",
                occurredAt: day(2, 10, 57),
                category: .food,
                confidence: 0.95,
                signalSource: .alias,
                status: .resolved,
                locationLat: 12.9352,
                locationLng: 77.6245,
                locationCity: "Bengaluru",
                locationStatus: .fulfilled
            ),
            Transaction(
                id: "tx_002",
                amountInr: 211.00,
                currency: "INR",
                merchantRaw: "RAZ*Swiggy",
                merchantNormalized: "Swiggy",
                vpa: nil,
                direction: .out,
                instrument: "card_3328",
                occurredAt: day(4, 21, 15),
                category: .food,
                confidence: 0.95,
                signalSource: .alias,
                status: .resolved,
                locationLat: 12.9716,
                locationLng: 77.5946,
                locationCity: "Bengaluru",
                locationStatus: .fulfilled
            ),
            Transaction(
                id: "tx_003",
                amountInr: 474.55,
                currency: "USD",
                merchantRaw: "Anthropic",
                merchantNormalized: "Anthropic",
                vpa: nil,
                direction: .out,
                instrument: "card_3803",
                occurredAt: day(6, 9, 0),
                category: .subscriptions,
                confidence: 0.95,
                signalSource: .autopayAlias,
                status: .resolved,
                locationLat: nil,
                locationLng: nil,
                locationCity: nil,
                locationStatus: .notApplicable
            ),
            Transaction(
                id: "tx_004",
                amountInr: 5000.00,
                currency: "INR",
                merchantRaw: "SNEHA R",
                merchantNormalized: "SNEHA R",
                vpa: "s.neha2003rajesh-1@okaxis",
                direction: .in,
                instrument: "account_5264",
                occurredAt: day(0, 18, 5),
                category: .personalTransfer,
                confidence: 0.7,
                signalSource: .vpaShape,
                status: .resolved,
                locationLat: nil,
                locationLng: nil,
                locationCity: nil,
                locationStatus: .notApplicable
            ),
            Transaction(
                id: "tx_005",
                amountInr: 94.00,
                currency: "INR",
                merchantRaw: "SRI GURU RAGHAVENDRA ENTERPRISES",
                merchantNormalized: "SRI GURU RAGHAVENDRA ENTERPRISES",
                vpa: "q201985284@ybl",
                direction: .out,
                instrument: "account_5264",
                occurredAt: day(7, 11, 0),
                category: nil,
                confidence: nil,
                signalSource: nil,
                status: .pendingReview,
                locationLat: 12.9249,
                locationLng: 77.5827,
                locationCity: "Jayanagar",
                locationStatus: .fulfilled
            ),
            Transaction(
                id: "tx_006",
                amountInr: 287.00,
                currency: "INR",
                merchantRaw: "RAJESH KUMAR",
                merchantNormalized: "RAJESH KUMAR",
                vpa: "rajesh.kumar2002@oksbi",
                direction: .out,
                instrument: "account_5264",
                occurredAt: day(1, 8, 42),
                category: .travel,
                confidence: 0.6,
                signalSource: .userRule,
                status: .pendingReview,
                locationLat: 12.9352,
                locationLng: 77.6245,
                locationCity: "Koramangala",
                locationStatus: .fulfilled
            ),
            Transaction(
                id: "tx_007",
                amountInr: 80.00,
                currency: "INR",
                merchantRaw: "Thimmegowda Sanjeevkumar",
                merchantNormalized: "Thimmegowda Sanjeevkumar",
                vpa: "paytmqr6fgl36@ptys",
                direction: .out,
                instrument: "card_2668",
                occurredAt: day(14, 9, 30),
                category: nil,
                confidence: nil,
                signalSource: nil,
                status: .pendingReview,
                locationLat: nil,
                locationLng: nil,
                locationCity: nil,
                locationStatus: .missed
            ),
        ]
    }()

    /// Items in the swipe-review stack — the txns whose status is pendingReview.
    static var reviewItems: [ReviewItem] {
        transactions
            .filter { $0.status == .pendingReview }
            .map { tx in
                let detail: String?
                switch tx.signalSource {
                case .userRule: detail = "Probable cab fare"
                case .vpaShape: detail = "VPA looks personal"
                case .alias, .autopayAlias: detail = "Known merchant"
                case .merchantPattern: detail = "Tagged this 3+ times"
                case .places: detail = "Nearby place"
                case .none: detail = nil
                }
                return ReviewItem(
                    id: tx.id,
                    transaction: tx,
                    suggestedCategory: tx.category,
                    suggestionDetail: detail
                )
            }
    }

    static let budgets: [Budget] = [
        Budget(category: .food, monthlyLimitInr: 5000),
        Budget(category: .travel, monthlyLimitInr: 3000),
        Budget(category: .entertainment, monthlyLimitInr: 1500),
        Budget(category: .shopping, monthlyLimitInr: 2000),
        Budget(category: .personalTransfer, monthlyLimitInr: nil),
        Budget(category: .investments, monthlyLimitInr: nil),
        Budget(category: .subscriptions, monthlyLimitInr: 800),
    ]
}
