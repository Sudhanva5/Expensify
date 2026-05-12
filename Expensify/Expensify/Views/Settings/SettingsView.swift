import SwiftUI

/// Settings sheet — presented from the avatar in any tab's nav bar.
/// Cred-style: lowercase section labels, tight typography, restrained color.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var budgets: [Budget] = MockData.budgets

    @State private var pingState: PingState = .idle
    @State private var pingResult: APIClient.PingResult?

    enum PingState { case idle, running, done }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColor.canvas.ignoresSafeArea()

                List {
                    profileSection
                    connectionSection
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
                Text("SA")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(AppColor.avatarFill)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sudhanva")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                    Text("sm.acharya@scaler.com")
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

    private var budgetsSection: some View {
        Section {
            ForEach($budgets) { $budget in
                NavigationLink {
                    BudgetEditView(budget: $budget)
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
}
