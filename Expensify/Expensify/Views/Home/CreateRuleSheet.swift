import SwiftUI

/// "Create a rule from this transaction" wizard. Pre-fills conditions
/// from the source transaction — amount ±20%, time ±1h IST, same
/// instrument, optional location-within-radius — and lets the user
/// toggle each one before saving.
///
/// Save fires POST /rules with confidence 0.95 (auto-tag threshold) so
/// the rule immediately resolves any matching future transactions.
struct CreateRuleSheet: View {
    let transaction: Transaction
    let category: Category

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var useAmount: Bool = true
    @State private var useTime: Bool = true
    @State private var useInstrument: Bool = true
    @State private var useLocation: Bool = false
    @State private var locationMeters: Double = 100
    @State private var saveState: SaveState = .idle
    @State private var saveError: String?

    enum SaveState { case idle, saving, saved }

    private let suggestion: UserRule.Conditions

    init(transaction: Transaction, category: Category) {
        self.transaction = transaction
        self.category = category
        let s = UserRule.Conditions.suggestion(from: transaction)
        self.suggestion = s
        _useLocation = State(initialValue: s.locationWithinRadius != nil)
        _locationMeters = State(initialValue: s.locationWithinRadius?.meters ?? 100)
        _name = State(initialValue: Self.defaultName(for: transaction, category: category))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColor.canvas.ignoresSafeArea()
                List {
                    Section {
                        TextField("rule name", text: $name)
                            .font(.system(size: 15))
                            .foregroundStyle(AppColor.textPrimary)
                    } header: {
                        Text("name").font(AppFont.sectionLabel).foregroundStyle(AppColor.textTertiary)
                    }

                    Section {
                        HStack {
                            Image(systemName: category.symbolName)
                                .frame(width: 24, height: 24)
                                .foregroundStyle(AppColor.textPrimary)
                            Text("tag as \(category.shortName)")
                                .font(.system(size: 15))
                                .foregroundStyle(AppColor.textPrimary)
                            Spacer()
                        }
                    } header: {
                        Text("action").font(AppFont.sectionLabel).foregroundStyle(AppColor.textTertiary)
                    }

                    Section {
                        conditionToggle(
                            "amount window",
                            detail: amountSummary,
                            isOn: $useAmount
                        )
                        conditionToggle(
                            "time window",
                            detail: timeSummary,
                            isOn: $useTime
                        )
                        conditionToggle(
                            "instrument",
                            detail: transaction.instrument,
                            isOn: $useInstrument
                        )
                        if suggestion.locationWithinRadius != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                conditionToggle(
                                    "near this location",
                                    detail: locationSummary,
                                    isOn: $useLocation
                                )
                                if useLocation {
                                    HStack {
                                        Text("radius")
                                            .font(AppFont.caption)
                                            .foregroundStyle(AppColor.textTertiary)
                                        Slider(value: $locationMeters, in: 20...500, step: 10)
                                        Text("\(Int(locationMeters))m")
                                            .font(AppFont.caption.monospacedDigit())
                                            .foregroundStyle(AppColor.textTertiary)
                                            .frame(width: 56, alignment: .trailing)
                                    }
                                }
                            }
                        } else {
                            HStack {
                                Text("near this location")
                                    .font(.system(size: 15))
                                    .foregroundStyle(AppColor.textTertiary)
                                Spacer()
                                Text("no GPS")
                                    .font(AppFont.caption)
                                    .foregroundStyle(AppColor.textTertiary)
                            }
                        }
                    } header: {
                        Text("conditions").font(AppFont.sectionLabel).foregroundStyle(AppColor.textTertiary)
                    } footer: {
                        Text("matching transactions get auto-tagged to \(category.shortName). edit or disable from settings → rules.")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                    }

                    if let err = saveError {
                        Section {
                            Text(err)
                                .font(AppFont.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppColor.canvas)
            }
            .navigationTitle("create rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                        .foregroundStyle(AppColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveState == .saving ? "saving…" : "save") {
                        Task { await save() }
                    }
                    .foregroundStyle(AppColor.textPrimary)
                    .disabled(saveState == .saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func conditionToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textPrimary)
                Text(detail)
                    .font(AppFont.caption.monospacedDigit())
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }

    private var amountSummary: String {
        guard let amt = suggestion.amountBetween, amt.count == 2 else { return "—" }
        return "₹\(Int(amt[0])) – ₹\(Int(amt[1]))"
    }
    private var timeSummary: String {
        guard let t = suggestion.timeOfDayBetween, t.count == 2 else { return "—" }
        return "\(t[0]) – \(t[1]) IST"
    }
    private var locationSummary: String {
        guard let l = suggestion.locationWithinRadius else { return "—" }
        return String(format: "%.4f, %.4f", l.lat, l.lng)
    }

    private static func defaultName(for tx: Transaction, category: Category) -> String {
        if let lat = tx.locationLat, let lng = tx.locationLng {
            _ = (lat, lng)
            return "\(category.shortName) near this spot"
        }
        return "\(category.shortName) like this one"
    }

    private func save() async {
        saveState = .saving
        saveError = nil

        var conditions = suggestion
        if !useAmount { conditions.amountBetween = nil }
        if !useTime { conditions.timeOfDayBetween = nil }
        if !useInstrument { conditions.instrument = nil }
        if useLocation, var loc = conditions.locationWithinRadius {
            loc.meters = locationMeters
            conditions.locationWithinRadius = loc
        } else {
            conditions.locationWithinRadius = nil
        }

        do {
            _ = try await APIClient.shared.createRule(
                name: name.trimmingCharacters(in: .whitespaces),
                category: category,
                conditions: conditions,
                priority: 100,
                confidence: 0.95
            )
            saveState = .saved
            dismiss()
        } catch {
            saveError = error.localizedDescription
            saveState = .idle
        }
    }
}
