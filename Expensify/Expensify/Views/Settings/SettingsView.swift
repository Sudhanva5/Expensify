import SwiftUI

/// Settings sheet — presented from the avatar in any tab's nav bar.
/// Cred-style: lowercase section labels, tight typography, restrained color.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BudgetStore.self) private var budgetStore

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
                    budgetsSection
                    rulesSection
                    diagnosticsSection
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

    /// Single navigation link to the diagnostics screen. Everything that
    /// used to live as separate rows (connection check, test push, reload
    /// contacts, sync google contacts, view recent matches) moved into
    /// DiagnosticsView so Settings stays focused on user-visible config.
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                        .frame(width: 24, height: 24)
                        .background(AppColor.avatarFill)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("diagnostics")
                        .font(.system(size: 15))
                        .foregroundStyle(AppColor.textPrimary)
                }
            }
        } header: {
            Text("system")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        } footer: {
            Text("connection check, test push preview, contact match diagnostics.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
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

    /// Contextual auto-tagging rules. The "create rule from this
    /// transaction" wizard creates these inline from the category
    /// picker; this row is the management surface — list/disable/delete.
    private var rulesSection: some View {
        Section {
            NavigationLink {
                ManageRulesView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                        .frame(width: 24, height: 24)
                        .background(AppColor.avatarFill)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("manage rules")
                        .font(.system(size: 15))
                        .foregroundStyle(AppColor.textPrimary)
                }
            }
        } header: {
            Text("rules")
                .font(AppFont.sectionLabel)
                .foregroundStyle(AppColor.textTertiary)
        } footer: {
            Text("rules auto-tag transactions matching contextual patterns — amount range, time of day, distance from a saved location. create them from any category picker.")
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
