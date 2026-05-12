import SwiftUI

/// One pill in the horizontal filter row above the Home transaction list.
/// Used for "All" + each instrument the user has transactions on.
struct InstrumentPill: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        isSelected
                            ? Color.white.opacity(0.25)
                            : Color.secondary.opacity(0.18)
                    )
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Maps an internal instrument string to a human-readable label.
///   "card_3328"   → "Card ••3328"
///   "account_5264" → "Account ••5264"
enum InstrumentLabel {
    static func display(for instrument: String) -> String {
        if instrument.hasPrefix("card_") {
            let last4 = instrument.replacingOccurrences(of: "card_", with: "")
            return "Card ••\(last4)"
        }
        if instrument.hasPrefix("account_") {
            let last4 = instrument.replacingOccurrences(of: "account_", with: "")
            return "Account ••\(last4)"
        }
        return instrument
    }
}

#Preview {
    HStack(spacing: 8) {
        InstrumentPill(label: "All", count: 7, isSelected: true) { }
        InstrumentPill(label: "Card ••3328", count: 2, isSelected: false) { }
        InstrumentPill(label: "Account ••5264", count: 3, isSelected: false) { }
    }
    .padding()
}
