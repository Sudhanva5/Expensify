import SwiftUI
import UIKit

/// Single home for every "is the system healthy?" affordance:
///
///   • connection check (health + auth)
///   • test push (synthetic budget-alert banner so you know exactly
///     what the real alert looks like before it ever fires)
///   • reload local contacts + google contacts sync
///   • contact-match preview (which local/google paths fired per row)
///
/// Settling everything here means the main Settings page stays focused
/// on user-visible config (budgets, rules, profile) — diagnostics live
/// behind one tap.
struct DiagnosticsView: View {
    @Environment(ContactsService.self) private var contactsService

    @State private var pingState: ActionState = .idle
    @State private var pingResult: APIClient.PingResult?

    @State private var testPushState: ActionState = .idle
    @State private var testPushResult: APIClient.TestPushResult?
    @State private var testPushError: String?

    @State private var contactsReloading: Bool = false

    @State private var googleSyncing: Bool = false
    @State private var googleSyncResult: APIClient.GoogleContactsSyncResult?
    @State private var googleSyncError: String?

    @State private var mcpHealth: MCPHealth?
    @State private var mcpTokens: [MCPToken] = []
    @State private var mcpLoading: Bool = false
    @State private var mcpError: String?
    @State private var revokingId: String?

    enum ActionState { case idle, running, done }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()
            List {
                connectionSection
                notificationsSection
                contactsSection
                mcpSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColor.canvas)
            .listSectionSpacing(.compact)
        }
        .navigationTitle("diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshMCP() }
        .refreshable { await refreshMCP() }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            Button {
                Task { await runPing() }
            } label: {
                HStack {
                    Text("test connection").foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    if pingState == .running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(pingState == .running)

            if let result = pingResult {
                pingRow("health", ok: result.healthOK, error: result.healthError)
                pingRow("auth", ok: result.authedOK, error: result.authedError)
            }
        } header: {
            Text("connection")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        } footer: {
            Text("verifies the backend is reachable and your api token is accepted.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    @ViewBuilder
    private func pingRow(_ label: String, ok: Bool, error: String?) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? AppColor.inflow : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 15)).foregroundStyle(AppColor.textPrimary)
                if let error, !ok {
                    Text(error)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(3)
                }
            }
            Spacer()
        }
    }

    private func runPing() async {
        pingState = .running
        pingResult = nil
        pingResult = await APIClient.shared.ping()
        pingState = .done
    }

    // MARK: - Test push (with banner preview)

    private var notificationsSection: some View {
        Section {
            // Preview of what the test push will look like as a banner
            // before you tap. Matches what the backend's test-push
            // endpoint actually sends so there's no guesswork.
            VStack(alignment: .leading, spacing: 6) {
                Text("preview")
                    .font(.system(size: 11, weight: .semibold).smallCaps())
                    .foregroundStyle(AppColor.textTertiary)
                NotificationBannerPreview(
                    title: previewTitle,
                    message: previewBody
                )
            }
            .padding(.vertical, 6)

            Button {
                Task { await runTestPush() }
            } label: {
                HStack {
                    Text("send test notification").foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    if testPushState == .running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(testPushState == .running)

            if let result = testPushResult {
                HStack(alignment: .top) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? AppColor.inflow : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("delivered to \(result.delivered) of \(result.deviceCount) device\(result.deviceCount == 1 ? "" : "s")")
                            .font(.system(size: 14))
                            .foregroundStyle(AppColor.textPrimary)
                        if let reason = result.reason {
                            Text("reason: \(reason)")
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.textTertiary)
                        }
                    }
                    Spacer()
                }
            } else if let err = testPushError {
                HStack(alignment: .top) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(4)
                }
            }
        } header: {
            Text("notifications")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        } footer: {
            Text("end-to-end check for the budget-alert pipeline. the preview above is exactly what an over-budget banner will look like.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    /// Title used both for the in-app preview and the backend test push.
    /// Must stay in sync with the literal sent by /devices/test-push on
    /// the server.
    private var previewTitle: String { "Test from Expensify" }
    private var previewBody: String { "Your budget alert pipeline is wired up correctly. Real alerts will land here." }

    private func runTestPush() async {
        testPushState = .running
        testPushResult = nil
        testPushError = nil
        do {
            testPushResult = try await APIClient.shared.sendTestPush()
        } catch {
            testPushError = error.localizedDescription
        }
        testPushState = .done
    }

    // MARK: - Contacts

    private var contactsSection: some View {
        Section {
            HStack {
                Text("permission").font(.system(size: 15)).foregroundStyle(AppColor.textPrimary)
                Spacer()
                Text(authLabel)
                    .font(AppFont.caption.monospaced())
                    .foregroundStyle(authColor)
            }
            HStack(alignment: .top) {
                Text("indexed").font(.system(size: 15)).foregroundStyle(AppColor.textPrimary)
                Spacer()
                Text(contactsService.diagnostics.summary)
                    .font(AppFont.caption.monospaced())
                    .foregroundStyle(AppColor.textTertiary)
                    .multilineTextAlignment(.trailing)
            }

            Button {
                Task {
                    contactsReloading = true
                    await contactsService.requestAccessAndLoad()
                    contactsReloading = false
                }
            } label: {
                HStack {
                    Text("reload local contacts").foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    if contactsReloading { ProgressView().controlSize(.small) }
                }
            }
            .disabled(contactsReloading)

            Button {
                Task { await runGoogleSync() }
            } label: {
                HStack {
                    Text("sync google contacts").foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    if googleSyncing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(googleSyncing)

            if let result = googleSyncResult {
                HStack(alignment: .top) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColor.inflow)
                    Text("fetched \(result.fetched), saved \(result.saved)")
                        .font(AppFont.caption.monospacedDigit())
                        .foregroundStyle(AppColor.textTertiary)
                    Spacer()
                }
            } else if let err = googleSyncError {
                HStack(alignment: .top) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(4)
                }
            }

            NavigationLink {
                ContactMatchPreview()
            } label: {
                Text("view recent matches").foregroundStyle(AppColor.textPrimary)
            }
        } header: {
            Text("contacts")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        } footer: {
            Text("local = iphone contacts (never leaves the device). google = people api cache (synced via 'sync google contacts'). recent matches shows which path supplied the photo on each row.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    private var authLabel: String {
        switch contactsService.authorization {
        case .notDetermined: return "not asked"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        case .limited: return "limited"
        }
    }
    private var authColor: Color {
        switch contactsService.authorization {
        case .authorized, .limited: return AppColor.inflow
        case .denied, .restricted: return .red
        case .notDetermined: return AppColor.textTertiary
        }
    }

    private func runGoogleSync() async {
        googleSyncing = true
        googleSyncResult = nil
        googleSyncError = nil
        do {
            googleSyncResult = try await APIClient.shared.syncGoogleContacts()
        } catch {
            googleSyncError = error.localizedDescription
        }
        googleSyncing = false
    }

    // MARK: - MCP (Model Context Protocol)
    //
    // Shows the running MCP service URL with a copy affordance, the
    // live online/offline status, and every OAuth-issued bearer that
    // has been minted via the consent flow on claude.ai web. Swipe a
    // row to revoke. Pull-to-refresh re-queries everything.

    @ViewBuilder
    private var mcpSection: some View {
        Section {
            mcpHeaderRow

            if let url = mcpHealth?.url, !url.isEmpty {
                Button {
                    UIPasteboard.general.string = "\(url)/mcp"
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColor.textTertiary)
                            .frame(width: 18)
                        Text(displayURL(url))
                            .font(.system(size: 13).monospaced())
                            .foregroundStyle(AppColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppColor.textTertiary)
                    }
                }
            }

            if mcpLoading && mcpTokens.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("loading connections…")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                    Spacer()
                }
            } else if let err = mcpError {
                HStack(alignment: .top) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(4)
                }
            } else if mcpTokens.isEmpty {
                Text("no connected clients yet. use the consent flow on claude.ai → connectors to authorize one.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            } else {
                ForEach(mcpTokens) { token in
                    MCPTokenRow(
                        token: token,
                        isRevoking: revokingId == token.id
                    ) {
                        Task { await revoke(token) }
                    }
                }
            }
        } header: {
            Text("mcp")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        } footer: {
            Text("expense solver exposes a read-only mcp server to claude (desktop, code, web). claude code / desktop use a static bearer; claude.ai web goes through the oauth consent flow above. swipe a connection to revoke it.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    /// Status pill row at the top of the MCP section — colored dot + label
    /// + "checked Nm ago". A spinning indicator replaces the dot while a
    /// fresh /health check is in flight.
    private var mcpHeaderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            statusDot
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColor.textPrimary)
                if let checkedAt = mcpHealth?.checkedAt {
                    Text("checked \(relativeTime(checkedAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
            Spacer()
            if mcpLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        guard let h = mcpHealth else { return AppColor.textTertiary }
        return h.online ? AppColor.inflow : .red
    }

    private var statusLabel: String {
        guard let h = mcpHealth else { return "checking…" }
        if h.online { return "online" }
        if let code = h.statusCode { return "offline · http \(code)" }
        return "offline"
    }

    private func displayURL(_ raw: String) -> String {
        raw.replacingOccurrences(of: "https://", with: "")
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func refreshMCP() async {
        mcpLoading = true
        mcpError = nil
        async let healthTask = APIClient.shared.fetchMCPHealth()
        do {
            mcpTokens = try await APIClient.shared.listMCPTokens()
        } catch {
            mcpError = error.localizedDescription
        }
        mcpHealth = await healthTask
        mcpLoading = false
    }

    private func revoke(_ token: MCPToken) async {
        revokingId = token.id
        defer { revokingId = nil }
        do {
            try await APIClient.shared.revokeMCPToken(id: token.id)
            // Optimistic update: mark this row revoked locally instead of
            // re-fetching the whole list. Cuts the perceived latency for
            // the row to gray out from ~300ms to instant.
            if let idx = mcpTokens.firstIndex(where: { $0.id == token.id }) {
                let existing = mcpTokens[idx]
                mcpTokens[idx] = MCPToken(
                    id: existing.id,
                    clientName: existing.clientName,
                    clientId: existing.clientId,
                    scope: existing.scope,
                    issuedAt: existing.issuedAt,
                    expiresAt: existing.expiresAt,
                    lastUsedAt: existing.lastUsedAt,
                    revokedAt: Date()
                )
            }
        } catch {
            mcpError = "revoke failed: \(error.localizedDescription)"
        }
    }
}

/// One MCP connection. Layout mirrors the rest of Settings — left
/// avatar tile with an icon, two-line text on the right, a small
/// revoke button at the trailing edge. Revoked tokens dim out but
/// stay visible so the user can see what was once connected.
private struct MCPTokenRow: View {
    let token: MCPToken
    let isRevoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: token.isActive ? "key.fill" : "key.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(token.isActive ? AppColor.tap : AppColor.textTertiary)
                .frame(width: 24, height: 24)
                .background(AppColor.avatarFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(token.clientName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(token.isActive ? AppColor.textPrimary : AppColor.textTertiary)
                Text(subtitle)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(AppColor.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if token.isActive {
                if isRevoking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("revoke", role: .destructive, action: onRevoke)
                        .buttonStyle(.borderless)
                        .font(.system(size: 13, weight: .medium))
                }
            } else {
                Text("revoked")
                    .font(.system(size: 11, weight: .medium).smallCaps())
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .opacity(token.isActive ? 1.0 : 0.6)
    }

    /// Compact provenance line — "issued N ago · last used M ago" when
    /// we have both; falls back gracefully when the token hasn't been
    /// used yet (just connected) or when it's been revoked.
    private var subtitle: String {
        let issued = "issued " + Self.relative(token.issuedAt)
        if let revoked = token.revokedAt {
            return "\(issued) · revoked " + Self.relative(revoked)
        }
        if let lastUsed = token.lastUsedAt {
            return "\(issued) · used " + Self.relative(lastUsed)
        }
        return "\(issued) · not used yet"
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Minimal iOS-banner-style preview — rounded rectangle with title and
/// body text, mirroring how the lock-screen / notification-center banner
/// renders the alert. Static; doesn't actually fire APNs.
private struct NotificationBannerPreview: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppColor.tap)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "indianrupeesign")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Expensify")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    Text("now")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textTertiary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.hairline, lineWidth: 0.5)
        )
    }
}
