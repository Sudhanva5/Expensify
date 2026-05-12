import SwiftUI

/// Floating bottom pill rail for filtering by instrument (debit account /
/// credit card). Sits above the tab bar and below the scroll content.
/// One "All" chip + one chip per instrument present in the current scope.
struct InstrumentDock: View {
    let instruments: [(instrument: String, count: Int)]
    @Binding var selected: String?

    private var totalCount: Int {
        instruments.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                DockChip(
                    icon: nil,
                    label: "all",
                    count: totalCount,
                    isSelected: selected == nil
                ) {
                    selected = nil
                }
                ForEach(instruments, id: \.instrument) { entry in
                    DockChip(
                        icon: Self.iconFor(entry.instrument),
                        label: InstrumentLabel.display(for: entry.instrument).lowercased(),
                        count: entry.count,
                        isSelected: selected == entry.instrument
                    ) {
                        selected = entry.instrument
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule().stroke(AppColor.hairline.opacity(0.6), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    /// SF Symbol that reflects the instrument type.
    ///   • Cards (RuPay or regular CC) → credit-card glyph
    ///   • Accounts (UPI from bank) → columns glyph (the universal "bank")
    private static func iconFor(_ instrument: String) -> String {
        if instrument.hasPrefix("card_") { return "creditcard.fill" }
        if instrument.hasPrefix("account_") { return "building.columns.fill" }
        return "wallet.pass.fill"
    }
}

private struct DockChip: View {
    let icon: String?
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : AppColor.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? AppColor.textPrimary : .clear)
            .foregroundStyle(isSelected ? .white : AppColor.textPrimary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var selected: String? = nil
    return VStack {
        Spacer()
        InstrumentDock(
            instruments: [
                ("account_5264", 12),
                ("card_3328", 4),
                ("card_3803", 2),
                ("card_2668", 1),
            ],
            selected: $selected
        )
    }
    .background(AppColor.canvas)
}
