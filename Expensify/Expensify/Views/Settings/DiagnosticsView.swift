import SwiftUI

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

    enum ActionState { case idle, running, done }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()
            List {
                connectionSection
                notificationsSection
                contactsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColor.canvas)
            .listSectionSpacing(.compact)
        }
        .navigationTitle("diagnostics")
        .navigationBarTitleDisplayMode(.inline)
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
                    body: previewBody
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
}

/// Minimal iOS-banner-style preview — rounded rectangle with title and
/// body text, mirroring how the lock-screen / notification-center banner
/// renders the alert. Static; doesn't actually fire APNs.
private struct NotificationBannerPreview: View {
    let title: String
    let body: String

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
                Text(body)
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
