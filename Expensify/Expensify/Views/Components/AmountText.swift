import SwiftUI

/// Rupee amount composed of three text pieces:
///   • Sign (optional "+" for inflows)
///   • Rupee symbol — rendered WITHOUT monospaced-digit (the glyph isn't a
///     digit; forcing monospacing on it makes ₹ look thin and oddly spaced)
///   • Integer portion — monospaced digits so columns of amounts align
///   • Decimal portion — smaller and muted
///
/// Inflows are green and prefixed `+`. Outflows stay in primary text color
/// (no red — red feels scolding for normal spending).
struct AmountText: View {
    let amount: Decimal
    let direction: Transaction.Direction
    var size: CGFloat = 16

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if direction == .in {
                Text("+")
                    .font(symbolFont)
                    .foregroundStyle(color)
            }
            Text("₹")
                .font(symbolFont)
                .foregroundStyle(color)
            Text(integerString)
                .font(digitFont)
                .foregroundStyle(color)
            Text(decimalString)
                .font(decimalFont)
                .foregroundStyle(decimalColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
    }

    // MARK: - Fonts

    private var symbolFont: Font {
        .system(size: size, weight: .semibold)
    }

    private var digitFont: Font {
        .system(size: size, weight: .semibold)
            .monospacedDigit()
    }

    private var decimalFont: Font {
        .system(size: size * 0.82, weight: .semibold)
            .monospacedDigit()
    }

    // MARK: - Colors

    private var color: Color {
        direction == .in ? AppColor.inflow : AppColor.textPrimary
    }

    private var decimalColor: Color {
        direction == .in ? AppColor.inflow.opacity(0.7) : AppColor.textTertiary
    }

    // MARK: - Strings

    private var doubleValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }

    private var integerString: String {
        let intValue = Int(doubleValue)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: intValue)) ?? "\(intValue)"
    }

    private var decimalString: String {
        let cents = Int((doubleValue.truncatingRemainder(dividingBy: 1) * 100).rounded())
        if cents == 0 { return "" }
        return String(format: ".%02d", cents)
    }

    private var accessibilityValue: String {
        let sign = direction == .in ? "Received" : "Spent"
        return "\(sign) ₹\(integerString)\(decimalString) rupees"
    }
}

#Preview {
    VStack(alignment: .trailing, spacing: 16) {
        AmountText(amount: 547.00, direction: .out)
        AmountText(amount: 1, direction: .out)
        AmountText(amount: 5000.00, direction: .in)
        AmountText(amount: 211.50, direction: .out)
        AmountText(amount: 23.60, direction: .out)
        AmountText(amount: 12345.67, direction: .out)
        AmountText(amount: 999, direction: .out, size: 32)
    }
    .padding()
}
