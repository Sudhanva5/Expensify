import Foundation

/// One OAuth-issued bearer token for the MCP server. Surfaces in
/// Settings → Diagnostics → MCP. The raw token bytes never leave the
/// server — `id` is the opaque revoke handle, everything else is for
/// human display.
struct MCPToken: Identifiable, Equatable, Sendable {
    let id: String
    /// Client-supplied name from dynamic registration (RFC 7591). Falls
    /// back to "Unknown client" when claude.ai web omits client_name.
    let clientName: String
    /// Internal id of the McpOAuthClient row this token belongs to.
    /// Surfaced only as a small monospace badge so the user can tell two
    /// "Claude" entries apart if both ever exist.
    let clientId: String
    let scope: String?
    let issuedAt: Date
    let expiresAt: Date?
    let lastUsedAt: Date?
    let revokedAt: Date?

    /// True until the user (or the server) marks it revoked.
    var isActive: Bool { revokedAt == nil }
}

/// Live status of the MCP service from the iOS app's vantage point.
/// `online` is the result of the most recent /mcp-admin/health check;
/// `url` is what the user should paste into a Claude client config.
struct MCPHealth: Sendable {
    let url: String
    let online: Bool
    let statusCode: Int?
    let error: String?
    let checkedAt: Date
}
