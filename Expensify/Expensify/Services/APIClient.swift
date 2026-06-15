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

    /// Rule conditions are stored verbatim in a JSONB column on the
    /// backend and read by the rule evaluator using exact (camelCase)
    /// keys like `amountBetween`, `locationWithinRadius`. The shared
    /// snake_case-converting encoder would mangle these into
    /// `amount_between` / `location_within_radius`, which the Zod
    /// validator rejects. Use a raw encoder for rule traffic.
    private let plainEncoder = JSONEncoder()
    private let plainDecoder = JSONDecoder()

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

    /// Claim a Nearby Places suggestion. Backend rewrites this row's
    /// merchantNormalized + category to match, then bulk-propagates BOTH
    /// fields to every same-VPA row in the user's history. The same
    /// effective fix as if the recategorize step had auto-resolved every
    /// row to the Places centroid in the first place.
    func applyPlace(
        transactionId: String,
        placesName: String,
        category: Category,
        latitude: Double?,
        longitude: Double?
    ) async throws -> Int {
        struct Body: Encodable {
            let placesName: String
            let category: String
            let lat: Double?
            let lng: Double?
        }
        let body = Body(
            placesName: placesName,
            category: category.rawValue,
            lat: latitude,
            lng: longitude
        )
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent("/transactions/\(transactionId)/apply-place"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        // Keep camelCase on the wire — the Zod schema uses placesName.
        req.httpBody = try plainEncoder.encode(body)
        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)
        struct Wire: Decodable { let ok: Bool; let bulkUpdated: Int }
        let w = try decoder.decode(Wire.self, from: data)
        return w.bulkUpdated
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

    // MARK: - Budgets

    private struct BudgetWire: Decodable {
        // Prisma's Budget.id is a CUID — a string, NOT a number. Previously
        // typed as Int, which silently broke every fetchBudgets() because
        // JSONDecoder threw on every response and the catch swallowed it,
        // leaving BudgetStore.byCategory empty on every cold start.
        let id: String
        let category: String
        let monthlyLimitInr: Decimal
        let alertThresholds: [Decimal]
        let enabled: Bool
    }

    /// Fetch every budget currently configured on the backend.
    func fetchBudgets() async throws -> [Budget] {
        let wires: [BudgetWire] = try await getJSON(path: "/budgets/")
        return wires.compactMap { wire in
            guard let cat = Category(rawValue: wire.category) else {
                return nil
            }
            let parts = Budget.fromBackendThresholds(wire.alertThresholds)
            return Budget(
                backendId: wire.id,
                category: cat,
                monthlyLimitInr: wire.monthlyLimitInr,
                alertAt80: parts.alertAt80,
                alertAt100: parts.alertAt100,
                alertAt110: parts.alertAt110,
                enabled: wire.enabled,
                extraThresholds: parts.extras
            )
        }
    }

    /// Create-or-update a budget. Server treats the category name as the
    /// natural key — one budget per category.
    func upsertBudget(_ budget: Budget) async throws -> Budget {
        struct Body: Encodable {
            let monthlyLimitInr: Decimal
            let alertThresholds: [Decimal]
            let enabled: Bool
        }
        guard let limit = budget.monthlyLimitInr, limit > 0 else {
            throw APIError.invalidResponse
        }
        let body = Body(
            monthlyLimitInr: limit,
            alertThresholds: budget.alertThresholdsForBackend,
            enabled: budget.enabled
        )

        // Critical: .urlPathAllowed lets `/` through unencoded. With the
        // older "Groceries / Kirana Stores" category name the bare `/`
        // decoded into THREE path segments at the Fastify side, missing
        // the /:categoryName route and returning 404. The name has since
        // been renamed to "Shopping", but the guard stays in case any
        // future category name contains a slash. Subtract `/` so the
        // slash gets %2F-encoded.
        // We also bypass URL.appendingPathComponent here because it re-
        // decodes the %2F back to a literal `/` on some iOS versions —
        // build the full URL string directly and parse it instead.
        let segmentSafe = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/"))
        let encodedName = budget.category.rawValue.addingPercentEncoding(
            withAllowedCharacters: segmentSafe
        ) ?? budget.category.rawValue
        guard let url = URL(string: "\(Constants.baseURL.absoluteString)/budgets/\(encodedName)") else {
            throw APIError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try encoder.encode(body)

        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)

        let wire = try decoder.decode(BudgetWire.self, from: data)
        guard let cat = Category(rawValue: wire.category) else {
            throw APIError.invalidResponse
        }
        let parts = Budget.fromBackendThresholds(wire.alertThresholds)
        return Budget(
            id: budget.id,
            backendId: wire.id,
            category: cat,
            monthlyLimitInr: wire.monthlyLimitInr,
            alertAt80: parts.alertAt80,
            alertAt100: parts.alertAt100,
            alertAt110: parts.alertAt110,
            enabled: wire.enabled,
            extraThresholds: parts.extras
        )
    }

    /// Delete the budget for a category. No-op if none exists.
    func deleteBudget(category: Category) async throws {
        // Same slash-encoding + URL-construction fix as upsertBudget.
        let segmentSafe = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/"))
        let encodedName = category.rawValue.addingPercentEncoding(
            withAllowedCharacters: segmentSafe
        ) ?? category.rawValue
        guard let url = URL(string: "\(Constants.baseURL.absoluteString)/budgets/\(encodedName)") else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)
    }

    // MARK: - User rules

    private struct RuleWire: Decodable {
        let id: String
        let name: String
        let priority: Int
        let enabled: Bool
        let conditions: UserRule.Conditions
        let category: String
        let confidence: Double
        let hitCount: Int
    }

    /// List every user-authored rule (enabled + disabled).
    func fetchRules() async throws -> [UserRule] {
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent("/rules/"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)

        // Top-level keys mix conventions (hit_count vs name), so decode the
        // outer envelope with the snake-case decoder. Conditions inside are
        // camelCase JSONB — Codable matches them by exact name since they
        // contain no underscores in the source struct.
        let wires = try decoder.decode([RuleWire].self, from: data)
        return wires.compactMap { w in
            guard let cat = Category(rawValue: w.category) else { return nil }
            return UserRule(
                id: w.id,
                name: w.name,
                priority: w.priority,
                enabled: w.enabled,
                conditions: w.conditions,
                category: cat,
                confidence: w.confidence,
                hitCount: w.hitCount
            )
        }
    }

    /// Create a rule. Sourced by the "Create rule from this transaction"
    /// wizard. Confidence defaults to 0.95 (auto-tag threshold) so a fresh
    /// rule immediately resolves matching transactions.
    func createRule(
        name: String,
        category: Category,
        conditions: UserRule.Conditions,
        priority: Int = 100,
        confidence: Double = 0.95
    ) async throws -> UserRule {
        struct Body: Encodable {
            let name: String
            let priority: Int
            let enabled: Bool
            let conditions: UserRule.Conditions
            let category: String
            let confidence: Double
        }
        let body = Body(
            name: name,
            priority: priority,
            enabled: true,
            conditions: conditions,
            category: category.rawValue,
            confidence: confidence
        )

        var req = URLRequest(url: Constants.baseURL.appendingPathComponent("/rules/"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        // Keep camelCase on the wire — the rule schema's nested condition
        // keys (amountBetween, locationWithinRadius, etc.) are validated
        // verbatim and stored verbatim into JSONB.
        req.httpBody = try plainEncoder.encode(body)

        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)
        let wire = try decoder.decode(RuleWire.self, from: data)
        guard let cat = Category(rawValue: wire.category) else {
            throw APIError.invalidResponse
        }
        return UserRule(
            id: wire.id,
            name: wire.name,
            priority: wire.priority,
            enabled: wire.enabled,
            conditions: wire.conditions,
            category: cat,
            confidence: wire.confidence,
            hitCount: wire.hitCount
        )
    }

    /// Edit an existing rule — used by the rule-row tap → editor flow.
    /// Patches name + category + conditions in a single call. Confidence
    /// and priority are left alone (the editor doesn't surface them and
    /// shouldn't silently overwrite). Mirrors createRule's wire-format
    /// choice (plainEncoder so the JSONB condition keys stay camelCase).
    func updateRule(
        id: String,
        name: String,
        category: Category,
        conditions: UserRule.Conditions
    ) async throws {
        struct Body: Encodable {
            let name: String
            let category: String
            let conditions: UserRule.Conditions
        }
        let body = Body(name: name, category: category.rawValue, conditions: conditions)
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent("/rules/\(id)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try plainEncoder.encode(body)
        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)
    }

    /// Flip enabled on an existing rule. Used by the manage-rules toggle.
    func setRuleEnabled(id: String, enabled: Bool) async throws {
        struct Body: Encodable { let enabled: Bool }
        try await patchNoContent(path: "/rules/\(id)", body: Body(enabled: enabled))
    }

    // MARK: - Google contacts

    struct GoogleContactLookup: Sendable {
        let resourceName: String
        let displayName: String?
        let photoUrl: String?
        let matchedOn: String
    }

    struct GoogleContactsSyncResult: Sendable {
        let fetched: Int
        let saved: Int
    }

    /// Trigger a fresh People API pull on the backend. The Google-contact
    /// cache is wiped + replaced atomically inside the request. Returns
    /// fetched (how many came back from the API) and saved (how many
    /// were persisted after filtering out blank rows / placeholders).
    func syncGoogleContacts() async throws -> GoogleContactsSyncResult {
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent("/contacts/sync"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = "{}".data(using: .utf8)
        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)
        struct Wire: Decodable { let ok: Bool; let fetched: Int; let saved: Int }
        let w = try decoder.decode(Wire.self, from: data)
        return GoogleContactsSyncResult(fetched: w.fetched, saved: w.saved)
    }

    /// Ask the backend for a Google-contact match against this VPA. The
    /// backend matches by phone-shaped local part first, then falls back
    /// to fuzzy name overlap on the merchant text. Returns nil when
    /// nothing matched (204 No Content) so callers can stay on the
    /// CNContactStore result.
    func googleContactLookup(
        vpa: String?,
        merchantRaw: String?
    ) async throws -> GoogleContactLookup? {
        var components = URLComponents(
            url: Constants.baseURL.appendingPathComponent("/contacts/google-lookup"),
            resolvingAgainstBaseURL: false
        )
        var items: [URLQueryItem] = []
        if let vpa, !vpa.isEmpty { items.append(URLQueryItem(name: "vpa", value: vpa)) }
        if let merchantRaw, !merchantRaw.isEmpty {
            items.append(URLQueryItem(name: "merchantRaw", value: merchantRaw))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw APIError.invalidResponse }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await HTTPClient.shared.send(req)
        if http.statusCode == 204 { return nil }
        try ensure2xx(http: http, data: data)

        struct Wire: Decodable {
            let resourceName: String
            let displayName: String?
            let photoUrl: String?
            let matchedOn: String
        }
        let w = try decoder.decode(Wire.self, from: data)
        return GoogleContactLookup(
            resourceName: w.resourceName,
            displayName: w.displayName,
            photoUrl: w.photoUrl,
            matchedOn: w.matchedOn
        )
    }

    /// Remove a rule entirely.
    func deleteRule(id: String) async throws {
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent("/rules/\(id)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)
    }

    // MARK: - Device + location

    /// Tell the backend about this device's APNs token so it can send silent pushes.
    func registerDevice(apnsToken: String) async throws {
        struct Body: Encodable { let apnsToken: String }
        try await postNoContent(path: "/devices/register", body: Body(apnsToken: apnsToken))
    }

    /// Fire a synthetic visible push to every device the backend knows
    /// about (right now: just this iPhone). Used by Settings →
    /// "Send test notification" to verify APNs delivery without
    /// having to cross a real budget threshold.
    func sendTestPush() async throws -> TestPushResult {
        struct Wire: Decodable {
            let ok: Bool
            let reason: String?
            let devices: [DeviceWire]
            struct DeviceWire: Decodable {
                let tokenPrefix: String
                let lastSeen: String
                let delivered: Bool
            }
        }

        var req = URLRequest(url: Constants.baseURL.appendingPathComponent("/devices/test-push"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Empty body — server only needs the auth header + registered devices.
        req.httpBody = "{}".data(using: .utf8)

        let (data, http) = try await HTTPClient.shared.send(req)
        try ensure2xx(http: http, data: data)
        let wire = try decoder.decode(Wire.self, from: data)
        return TestPushResult(
            ok: wire.ok,
            reason: wire.reason,
            deviceCount: wire.devices.count,
            delivered: wire.devices.filter { $0.delivered }.count
        )
    }

    struct TestPushResult: Sendable {
        let ok: Bool
        /// Server-supplied reason when ok=false (e.g. "no_registered_devices").
        let reason: String?
        let deviceCount: Int
        let delivered: Int
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

    // MARK: - MCP diagnostics
    //
    // Read-only inspection + revoke surface for OAuth-issued bearers on the
    // MCP service. The MAIN backend owns these endpoints because iOS already
    // holds the main API_TOKEN — keeping the iOS auth model unchanged. The
    // main backend reads/writes the McpAccessToken table directly (shared
    // Postgres) and proxies a health-check at MCP_PUBLIC_URL/health.

    /// Hit the main backend's MCP health proxy. Falls back to an `online:false`
    /// result on any error so the UI can render an offline badge without
    /// throwing.
    func fetchMCPHealth() async -> MCPHealth {
        struct Wire: Decodable {
            let ok: Bool
            let url: String?
            let statusCode: Int?
            let error: String?
            let checkedAt: String?
        }
        do {
            let wire: Wire = try await getJSON(path: "/mcp-admin/health")
            let checked = wire.checkedAt.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
            return MCPHealth(
                url: wire.url ?? "",
                online: wire.ok,
                statusCode: wire.statusCode,
                error: wire.error,
                checkedAt: checked
            )
        } catch {
            return MCPHealth(
                url: "",
                online: false,
                statusCode: nil,
                error: error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    /// List every OAuth access token the MCP server has issued, newest
    /// first. Revoked tokens are NOT filtered out — the UI grays them
    /// out so the user can see what was previously connected.
    func listMCPTokens() async throws -> [MCPToken] {
        struct Wire: Decodable {
            let count: Int
            let tokens: [TokenWire]
            struct TokenWire: Decodable {
                let id: String
                let clientName: String?
                let clientId: String
                let scope: String?
                let issuedAt: String
                let expiresAt: String?
                let lastUsedAt: String?
                let revokedAt: String?
            }
        }
        let wire: Wire = try await getJSON(path: "/mcp-admin/tokens")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        let parse: (String?) -> Date? = { s in
            guard let s, !s.isEmpty else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }
        return wire.tokens.map { t in
            MCPToken(
                id: t.id,
                clientName: t.clientName?.trimmingCharacters(in: .whitespaces).isEmpty == false
                    ? t.clientName!
                    : "Unknown client",
                clientId: t.clientId,
                scope: t.scope,
                issuedAt: parse(t.issuedAt) ?? Date(),
                expiresAt: parse(t.expiresAt),
                lastUsedAt: parse(t.lastUsedAt),
                revokedAt: parse(t.revokedAt)
            )
        }
    }

    /// Revoke an MCP-issued access token. After this returns, the next
    /// /mcp request bearing that token 401s. Idempotent — revoking a
    /// previously-revoked token is a no-op success.
    func revokeMCPToken(id: String) async throws {
        var req = URLRequest(url: Constants.baseURL.appendingPathComponent("/mcp-admin/tokens/\(id)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(Constants.apiToken)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await HTTPClient.shared.send(req)
        // 404 = already gone; treat as success for revoke semantics.
        if http.statusCode == 404 { return }
        try ensure2xx(http: http, data: data)
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
