import SwiftUI

/// Modal sheet presented when the user taps the avatar in any tab's nav bar.
/// Shows profile, per-category budgets, and account actions.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var budgets: [Budget] = MockData.budgets

    @State private var pingState: PingState = .idle
    @State private var pingResult: APIClient.PingResult?

    enum PingState {
        case idle
        case running
        case done
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                connectionSection
                budgetsSection
                accountSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        Section("Profile") {
            HStack(spacing: 12) {
                Text("SA")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sudhanva")
                        .font(.subheadline.weight(.semibold))
                    Text("sm.acharya@scaler.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
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
            Text("Budgets")
        } footer: {
            Text("Set a monthly limit per category. We'll notify you as you approach or cross it.")
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                Task { await runPing() }
            } label: {
                HStack {
                    Text("Test backend connection")
                    Spacer()
                    if pingState == .running {
                        ProgressView()
                    }
                }
            }
            .disabled(pingState == .running)

            if let result = pingResult {
                pingRow("GET /health", ok: result.healthOK, error: result.healthError)
                pingRow("POST /devices/register (auth)", ok: result.authedOK, error: result.authedError)
                if let host = Constants.baseURL.host {
                    HStack {
                        Text("Host")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Health is unauthenticated; auth call uses your API_TOKEN. Both should pass.")
        }
    }

    @ViewBuilder
    private func pingRow(_ label: String, ok: Bool, error: String?) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                if let error, !ok {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var accountSection: some View {
        Section("Account") {
            Button(role: .destructive) {
                // V1: stub
            } label: {
                Text("Sign out")
            }
        }
    }
}

private struct BudgetSummaryRow: View {
    let budget: Budget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: budget.category.symbolName)
                .frame(width: 24, height: 24)
                .foregroundStyle(budget.category.tint)

            Text(budget.category.shortName)
                .font(.subheadline)

            Spacer()

            Text(limitString)
                .font(.subheadline)
                .foregroundStyle(budget.isSet ? .primary : .secondary)
        }
    }

    private var limitString: String {
        guard let amount = budget.monthlyLimitInr else { return "Not set" }
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
