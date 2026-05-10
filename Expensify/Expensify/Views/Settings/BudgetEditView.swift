import SwiftUI

/// Pushed when the user taps a budget row in Settings. Lets them set the
/// monthly limit and toggle alert thresholds.
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
        Form {
            Section {
                HStack {
                    Text("₹")
                        .foregroundStyle(.secondary)
                    TextField("e.g. 5000", text: $draftLimit)
                        .keyboardType(.numberPad)
                }
            } header: {
                Text("Monthly limit")
            } footer: {
                Text("Spending in this category resets at the start of every month.")
            }

            Section {
                Toggle("Warn at 80%", isOn: $budget.alertAt80)
                Toggle("Notify at 100%", isOn: $budget.alertAt100)
                Toggle("Alert when over budget (110%)", isOn: $budget.alertAt110)
            } header: {
                Text("Alerts")
            } footer: {
                Text("You'll get a push notification once per threshold per month.")
            }

            Section {
                Button(role: .destructive) {
                    budget.monthlyLimitInr = nil
                    draftLimit = ""
                } label: {
                    Text("Remove budget")
                }
            }
        }
        .navigationTitle(budget.category.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let value = Decimal(string: draftLimit), value > 0 {
                        budget.monthlyLimitInr = value
                    } else {
                        budget.monthlyLimitInr = nil
                    }
                    dismiss()
                }
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
