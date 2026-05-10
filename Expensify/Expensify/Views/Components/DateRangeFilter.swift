import SwiftUI

/// Date-range selector used by Home and Categories. Three modes —
/// day, month, custom — implemented as a Menu with three options.
/// On selection, opens the appropriate picker as a sheet.
struct DateRangeFilter: View {
    @Binding var range: DateRange
    @State private var showingDayPicker = false
    @State private var showingMonthPicker = false
    @State private var showingCustomPicker = false

    @State private var workingDay: Date = Date()
    @State private var workingMonthYear: Int = 2026
    @State private var workingMonth: Int = 5
    @State private var workingStart: Date = Date()
    @State private var workingEnd: Date = Date()

    var body: some View {
        Menu {
            Button("Day") {
                workingDay = currentDayCandidate()
                showingDayPicker = true
            }
            Button("Month") {
                let comps = currentMonthCandidate()
                workingMonthYear = comps.year
                workingMonth = comps.month
                showingMonthPicker = true
            }
            Button("Custom") {
                let (s, e) = currentCustomCandidate()
                workingStart = s
                workingEnd = e
                showingCustomPicker = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(range.label)
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
            .foregroundStyle(.primary)
        }
        .sheet(isPresented: $showingDayPicker) { dayPickerSheet }
        .sheet(isPresented: $showingMonthPicker) { monthPickerSheet }
        .sheet(isPresented: $showingCustomPicker) { customPickerSheet }
    }

    // MARK: - Sheets

    private var dayPickerSheet: some View {
        NavigationStack {
            DatePicker("Select day", selection: $workingDay, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Pick a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingDayPicker = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            range = .day(workingDay)
                            showingDayPicker = false
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private var monthPickerSheet: some View {
        NavigationStack {
            VStack {
                HStack(spacing: 16) {
                    Picker("Month", selection: $workingMonth) {
                        ForEach(1...12, id: \.self) { m in
                            Text(monthName(m)).tag(m)
                        }
                    }
                    .pickerStyle(.wheel)

                    Picker("Year", selection: $workingMonthYear) {
                        ForEach(2024...2030, id: \.self) { y in
                            Text(String(y)).tag(y)
                        }
                    }
                    .pickerStyle(.wheel)
                }
                .padding()
                Spacer()
            }
            .navigationTitle("Pick a month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingMonthPicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        range = .month(year: workingMonthYear, month: workingMonth)
                        showingMonthPicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var customPickerSheet: some View {
        NavigationStack {
            Form {
                DatePicker("Start", selection: $workingStart, displayedComponents: .date)
                DatePicker("End", selection: $workingEnd, in: workingStart..., displayedComponents: .date)
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCustomPicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        range = .custom(start: workingStart, end: workingEnd)
                        showingCustomPicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Candidate helpers

    private func currentDayCandidate() -> Date {
        if case .day(let d) = range { return d }
        return Date()
    }

    private func currentMonthCandidate() -> (year: Int, month: Int) {
        if case .month(let y, let m) = range { return (y, m) }
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return (comps.year ?? 2026, comps.month ?? 5)
    }

    private func currentCustomCandidate() -> (Date, Date) {
        if case .custom(let s, let e) = range { return (s, e) }
        let now = Date()
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        return (weekAgo, now)
    }

    private func monthName(_ m: Int) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMMM"
        let comps = DateComponents(year: 2026, month: m, day: 1)
        return df.string(from: Calendar.current.date(from: comps) ?? Date())
    }
}

#Preview {
    @Previewable @State var r: DateRange = .defaultRange
    return DateRangeFilter(range: $r)
        .padding()
}
