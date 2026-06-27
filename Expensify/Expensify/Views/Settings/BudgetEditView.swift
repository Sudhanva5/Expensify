import SwiftUI

/// Pushed when the user taps a budget row in Settings.
/// Cred-style lowercase section labels, restrained typography.
///
/// All writes go through `BudgetStore.upsert(_:)` / `remove(_:)`, which
/// optimistically updates local state and posts to Railway. The view holds
/// a local draft until "save" is tapped so the user can back out cleanly.
struct BudgetEditView: View {
    let initial: Budget
    @Environment(BudgetStore.self) private var budgetStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftLimit: String
    @State private var alertAt80: Bool
    @State private var alertAt100: Bool
    @State private var alertAt110: Bool
    @State private var saving: Bool = false

    init(initial: Budget) {
        self.initial = initial
        if let amount = initial.monthlyLimitInr {
            self._draftLimit = State(
                initialValue: String(NSDecimalNumber(decimal: amount).intValue)
            )
        } else {
            self._draftLimit = State(initialValue: "")
        }
        self._alertAt80 = State(initialValue: initial.alertAt80)
        self._alertAt100 = State(initialValue: initial.alertAt100)
        self._alertAt110 = State(initialValue: initial.alertAt110)
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()

            Form {
                Section {
                    HStack {
                        Text("₹")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColor.textTertiary)
                        TextField("e.g. 5000", text: $draftLimit)
                            .font(.system(size: 16, weight: .medium).monospacedDigit())
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
                    Toggle("warn at 80%", isOn: $alertAt80)
                    Toggle("notify at 100%", isOn: $alertAt100)
                    Toggle("alert when over budget (110%)", isOn: $alertAt110)
                } header: {
                    Text("alerts")
                        .font(AppFont.sectionLabel)
                        .foregroundStyle(AppColor.textTertiary)
                } footer: {
                    Text("you'll get a push notification once per threshold per month.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                }

                if initial.isSet {
                    Section {
                        Button(role: .destructive) {
                            Task { await removeBudget() }
                        } label: {
                            Text("remove budget")
                        }
                        .disabled(saving)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColor.canvas)
        }
        .navigationTitle(initial.category.shortName.lowercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("save") {
                    Task { await save() }
                }
                .foregroundStyle(AppColor.tap)
                .disabled(saving)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }

        // Empty or zero → treat as "remove".
        guard let parsed = Decimal(string: draftLimit), parsed > 0 else {
            if initial.isSet {
                await budgetStore.remove(initial.category)
            }
            dismiss()
            return
        }

        let updated = Budget(
            id: initial.id,
            backendId: initial.backendId,
            category: initial.category,
            monthlyLimitInr: parsed,
            alertAt80: alertAt80,
            alertAt100: alertAt100,
            alertAt110: alertAt110,
            enabled: initial.enabled,
            extraThresholds: initial.extraThresholds
        )
        await budgetStore.upsert(updated)
        dismiss()
    }

    private func removeBudget() async {
        saving = true
        defer { saving = false }
        await budgetStore.remove(initial.category)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        BudgetEditView(initial: Budget(category: .food, monthlyLimitInr: 5000))
            .environment(BudgetStore())
    }
}
