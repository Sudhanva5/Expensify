import SwiftUI
import CoreLocation

/// Manual rule-creation form. Opened from the "+" toolbar button in
/// ManageRulesView. Starts blank — the user describes a pattern from
/// memory ("everything I pay near my mom's place is personal-transfer",
/// "weekends 8-11pm Food is Entertainment").
///
/// Keeps the surface area small: name, category, optional amount window,
/// optional time window, optional location radius. Day-of-week, payee
/// regex, and VPA-shape conditions live in the JSONB column and can be
/// added by editing the rule directly in the DB if the user needs them.
struct RuleEditorSheet: View {
    /// Existing rule to edit. When nil the sheet creates a new rule.
    /// When set the sheet pre-fills every toggle/field from the rule
    /// and PATCHes /rules/:id on save instead of POSTing /rules.
    var editing: UserRule? = nil
    /// Fires after a successful save so the parent list can refresh.
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var category: Category = .travel
    @State private var useAmount: Bool = true
    @State private var amountLow: Double = 100
    @State private var amountHigh: Double = 500
    @State private var useTime: Bool = false
    @State private var startTime: Date = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime: Date = Calendar.current.date(bySettingHour: 10, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var useLocation: Bool = false
    @State private var latText: String = ""
    @State private var lngText: String = ""
    @State private var radiusMeters: Double = 100
    @State private var locating: Bool = false
    @State private var saving: Bool = false
    @State private var saveError: String?
    @State private var hydrated: Bool = false

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
                        Picker("category", selection: $category) {
                            ForEach(Category.allCases) { cat in
                                Text(cat.shortName).tag(cat)
                            }
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text("tag as").font(AppFont.sectionLabel).foregroundStyle(AppColor.textTertiary)
                    }

                    Section {
                        Toggle("amount window", isOn: $useAmount)
                        if useAmount {
                            HStack {
                                Text("from").foregroundStyle(AppColor.textTertiary).font(AppFont.caption)
                                TextField("100", value: $amountLow, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                Text("to").foregroundStyle(AppColor.textTertiary).font(AppFont.caption)
                                TextField("500", value: $amountHigh, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                Text("₹").foregroundStyle(AppColor.textTertiary).font(AppFont.caption)
                            }
                        }
                    } header: {
                        Text("conditions").font(AppFont.sectionLabel).foregroundStyle(AppColor.textTertiary)
                    }

                    Section {
                        Toggle("time of day (IST)", isOn: $useTime)
                        if useTime {
                            DatePicker("from", selection: $startTime, displayedComponents: .hourAndMinute)
                            DatePicker("to", selection: $endTime, displayedComponents: .hourAndMinute)
                        }
                    }

                    Section {
                        Toggle("near a location", isOn: $useLocation)
                        if useLocation {
                            HStack {
                                Text("lat").foregroundStyle(AppColor.textTertiary).font(AppFont.caption)
                                TextField("12.8386", text: $latText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .multilineTextAlignment(.trailing)
                            }
                            HStack {
                                Text("lng").foregroundStyle(AppColor.textTertiary).font(AppFont.caption)
                                TextField("77.6647", text: $lngText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .multilineTextAlignment(.trailing)
                            }
                            HStack {
                                Text("radius")
                                    .font(AppFont.caption)
                                    .foregroundStyle(AppColor.textTertiary)
                                Slider(value: $radiusMeters, in: 20...1000, step: 10)
                                Text("\(Int(radiusMeters))m")
                                    .font(AppFont.caption.monospacedDigit())
                                    .foregroundStyle(AppColor.textTertiary)
                                    .frame(width: 60, alignment: .trailing)
                            }
                            Button {
                                Task { await captureCurrentLocation() }
                            } label: {
                                HStack {
                                    Image(systemName: "location.fill")
                                    Text("use current location")
                                    Spacer()
                                    if locating { ProgressView().controlSize(.small) }
                                }
                                .foregroundStyle(AppColor.tap)
                            }
                            .disabled(locating)
                        }
                    }

                    if let err = saveError {
                        Section {
                            Text(err).font(AppFont.caption).foregroundStyle(.red)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppColor.canvas)
            }
            .navigationTitle(editing == nil ? "new rule" : "edit rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                        .foregroundStyle(AppColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "saving…" : "save") { Task { await save() } }
                        .foregroundStyle(AppColor.tap)
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { hydrateIfNeeded() }
        }
    }

    /// Pre-fill every field from `editing` exactly once. Idempotent
    /// across redraws via the `hydrated` flag — without it, SwiftUI's
    /// state model would overwrite the user's in-flight edits whenever
    /// the body re-evaluates.
    private func hydrateIfNeeded() {
        guard !hydrated, let rule = editing else { return }
        hydrated = true
        name = rule.name
        category = rule.category
        let c = rule.conditions
        if let amt = c.amountBetween, amt.count == 2 {
            useAmount = true
            amountLow = amt[0]
            amountHigh = amt[1]
        } else {
            useAmount = false
        }
        if let t = c.timeOfDayBetween, t.count == 2 {
            useTime = true
            startTime = Self.parseHHMM(t[0]) ?? startTime
            endTime = Self.parseHHMM(t[1]) ?? endTime
        } else {
            useTime = false
        }
        if let loc = c.locationWithinRadius {
            useLocation = true
            latText = String(format: "%.6f", loc.lat)
            lngText = String(format: "%.6f", loc.lng)
            radiusMeters = loc.meters
        } else {
            useLocation = false
        }
    }

    private static func parseHHMM(_ s: String) -> Date? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
        return c.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }

    private func captureCurrentLocation() async {
        locating = true
        defer { locating = false }
        do {
            let loc = try await LocationService.shared.fetchOnce(minimumAccuracyMeters: 50, timeoutSeconds: 8)
            latText = String(format: "%.6f", loc.coordinate.latitude)
            lngText = String(format: "%.6f", loc.coordinate.longitude)
        } catch {
            saveError = "couldn't capture location: \(error.localizedDescription)"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        saveError = nil

        var conditions = UserRule.Conditions(
            direction: "out",
            instrument: nil,
            amountBetween: nil,
            timeOfDayBetween: nil,
            dayOfWeek: nil,
            payeeContains: nil,
            payeeRegex: nil,
            payeeNotInAliasTable: nil,
            vpaShape: nil,
            locationWithinRadius: nil
        )

        if useAmount {
            let lo = min(amountLow, amountHigh)
            let hi = max(amountLow, amountHigh)
            conditions.amountBetween = [lo, hi]
        }
        if useTime {
            let cal = Calendar(identifier: .gregorian)
            var c = cal
            c.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
            let s = c.dateComponents([.hour, .minute], from: startTime)
            let e = c.dateComponents([.hour, .minute], from: endTime)
            let start = String(format: "%02d:%02d", s.hour ?? 0, s.minute ?? 0)
            let end = String(format: "%02d:%02d", e.hour ?? 0, e.minute ?? 0)
            conditions.timeOfDayBetween = [start, end]
        }
        if useLocation {
            guard let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
                  let lng = Double(lngText.trimmingCharacters(in: .whitespaces)) else {
                saveError = "latitude and longitude must be numbers"
                return
            }
            conditions.locationWithinRadius = UserRule.Conditions.LocationCondition(
                lat: lat, lng: lng, meters: radiusMeters
            )
        }

        do {
            if let existing = editing {
                try await APIClient.shared.updateRule(
                    id: existing.id,
                    name: name.trimmingCharacters(in: .whitespaces),
                    category: category,
                    conditions: conditions
                )
            } else {
                _ = try await APIClient.shared.createRule(
                    name: name.trimmingCharacters(in: .whitespaces),
                    category: category,
                    conditions: conditions,
                    priority: 100,
                    confidence: 0.95
                )
            }
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
