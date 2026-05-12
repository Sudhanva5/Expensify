import SwiftUI

/// Pushed when the user taps a budget row in Settings.
/// Cred-style lowercase section labels, restrained typography.
struct BudgetEditView: View {
    @Binding var budget: Budget
    @Environment(\.dismiss) private var dismiss

    @State private var draftLimit: String

    init(budget: Binding<Budget>) {
        self._budget = budget
        let raw = budget.wrappedValue.monthlyLimitInr
        if let amount = raw {
            self._draftLimit = State(
                initialValue: String(NSDecimalNumber(decimal: amount).intValue)
            )
        } else {
            self._draftLimit = State(initialValue: "")
        }
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            Form {
                Section {
                    HStack {
                        Text("₹")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppColor.textTertiary)
                        TextField("e.g. 5000", text: $draftLimit)
                            .font(.system(size: 16, weight: .medium, design: .rounded).monospacedDigit())
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("monthly limit")
                        .font(AppFont.sectionLabel)
                        .foregroundStyle(AppColor.textTertiary)
                } footer: {
                    Text("spending in this category resets at the start of every month.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                }

                Section {
                    Toggle("warn at 80%", isOn: $budget.alertAt80)
                    Toggle("notify at 100%", isOn: $budget.alertAt100)
                    Toggle("alert when over budget (110%)", isOn: $budget.alertAt110)
                } header: {
                    Text("alerts")
                        .font(AppFont.sectionLabel)
                        .foregroundStyle(AppColor.textTertiary)
                } footer: {
                    Text("you'll get a push notification once per threshold per month.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                }

                Section {
                    Button(role: .destructive) {
                        budget.monthlyLimitInr = nil
                        draftLimit = ""
                    } label: {
                        Text("remove budget")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColor.canvas)
        }
        .navigationTitle(budget.category.shortName.lowercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("save") {
                    if let value = Decimal(string: draftLimit), value > 0 {
                        budget.monthlyLimitInr = value
                    } else {
                        budget.monthlyLimitInr = nil
                    }
                    dismiss()
                }
                .foregroundStyle(AppColor.textPrimary)
            }
        }
    }
}

#Preview {
    @Previewable @State var b = Budget(category: .food, monthlyLimitInr: 5000)
    NavigationStack {
        BudgetEditView(budget: $b)
    }
}
