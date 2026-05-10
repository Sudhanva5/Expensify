import SwiftUI

/// Modal sheet presented when the user taps the avatar in any tab's nav bar.
/// Shows profile, per-category budgets, and account actions.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var budgets: [Budget] = MockData.budgets

    var body: some View {
        NavigationStack {
            List {
                profileSection
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
