import SwiftUI

/// Settings sheet — presented from the avatar in any tab's nav bar.
/// Cred-style: lowercase section labels, tight typography, restrained color.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BudgetStore.self) private var budgetStore
    @Environment(ContactsService.self) private var contactsService

    @State private var pingState: PingState = .idle
    @State private var pingResult: APIClient.PingResult?
    @State private var contactsReloading: Bool = false
    @State private var testPushState: PingState = .idle
    @State private var testPushResult: APIClient.TestPushResult?
    @State private var testPushError: String?

    enum PingState { case idle, running, done }

    /// One row per category. Categories without a backend budget get a
    /// placeholder "not set" Budget so the user can tap in and create one.
    private var allBudgetRows: [Budget] {
        Category.allCases.map { budgetStore.budget(for: $0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColor.canvas.ignoresSafeArea()

                List {
                    profileSection
                    connectionSection
                    notificationsSection
                    contactsSection
                    budgetsSection
                    accountSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppColor.canvas)
                .listSectionSpacing(.compact)
            }
            .navigationTitle("settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                        .foregroundStyle(AppColor.textPrimary)
                }
            }
        }
    }

    private var profileSection: some View {
        Section {
            HStack(spacing: 12) {
                Text(CurrentUser.initials)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(AppColor.avatarFill)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(CurrentUser.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                    Text(CurrentUser.email)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                Task { await runPing() }
            } label: {
                HStack {
                    Text("test connection")
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    if pingState == .running {
                        ProgressView().controlSize(.small)
                    }
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
        }
    }

    @ViewBuilder
    private func pingRow(_ label: String, ok: Bool, error: String?) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? AppColor.inflow : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textPrimary)
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
        let result = await APIClient.shared.ping()
        pingResult = result
        pingState = .done
    }

    /// Sends a synthetic visible push to every registered device via the
    /// backend's `/devices/test-push` endpoint. Used to verify APNs
    /// delivery without waiting for a real budget threshold to trip.
    /// Shows result inline: device count, delivery success/fail, or the
    /// error message if the endpoint itself failed.
    private var notificationsSection: some View {
        Section {
            Button {
                Task { await runTestPush() }
            } label: {
                HStack {
                    Text("send test notification")
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    if testPushState == .running {
                        ProgressView().controlSize(.small)
                    }
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
            } else if let error = testPushError {
                HStack(alignment: .top) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
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
            Text("verifies the budget-alert push pipeline end-to-end. if you don't see a banner within ~10 seconds, check iOS Settings → Expensify → Notifications.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    private func runTestPush() async {
        testPushState = .running
        testPushResult = nil
        testPushError = nil
        do {
            let result = try await APIClient.shared.sendTestPush()
            testPushResult = result
        } catch {
            testPushError = error.localizedDescription
        }
        testPushState = .done
    }

    /// Surface contact-matching state so the user can tell whether the
    /// in-app contacts index is healthy. Shows authorization status, total
    /// contacts loaded, and how many of them have a photo cached. A
    /// `0 photos cached` row with hundreds of contacts means we couldn't
    /// pull the image data — usually a permission or sync-state issue.
    private var contactsSection: some View {
        Section {
            HStack {
                Text("permission")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Text(authLabel)
                    .font(AppFont.caption.monospaced())
                    .foregroundStyle(authColor)
            }
            HStack(alignment: .top) {
                Text("indexed")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textPrimary)
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
                    Text("reload contacts")
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    if contactsReloading {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(contactsReloading)

            // Diagnostic: per-row breakdown of which payees matched
            // which contacts and whether each has a photo cached.
            NavigationLink {
                ContactMatchPreview()
            } label: {
                Text("view recent matches")
                    .foregroundStyle(AppColor.textPrimary)
            }
        } header: {
            Text("contacts")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        } footer: {
            Text("if photos aren't showing on P2P rows, tap 'view recent matches' — that shows which payees matched contacts and whether each contact has a photo. A 'matched · no photo' line means the contact exists in your address book but doesn't have a profile picture saved.")
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

    private var budgetsSection: some View {
        Section {
            ForEach(allBudgetRows) { budget in
                NavigationLink {
                    BudgetEditView(initial: budget)
                } label: {
                    BudgetSummaryRow(budget: budget)
                }
            }
        } header: {
            Text("budgets")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        } footer: {
            Text("set a monthly limit per category. we'll notify you as you approach or cross it.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    private var accountSection: some View {
        Section {
            Button(role: .destructive) { } label: {
                Text("sign out")
            }
        } header: {
            Text("account")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        }
    }
}

private struct BudgetSummaryRow: View {
    let budget: Budget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: budget.category.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .frame(width: 24, height: 24)
                .background(AppColor.avatarFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(budget.category.shortName)
                .font(.system(size: 15))
                .foregroundStyle(AppColor.textPrimary)

            Spacer()

            Text(limitString)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(budget.isSet ? AppColor.textPrimary : AppColor.textTertiary)
        }
    }

    private var limitString: String {
        guard let amount = budget.monthlyLimitInr else { return "not set" }
        let value = NSDecimalNumber(decimal: amount).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "₹\(f.string(from: NSNumber(value: value)) ?? String(value))"
    }
}

#Preview {
    SettingsView()
        .environment(BudgetStore())
        .environment(ContactsService())
}
