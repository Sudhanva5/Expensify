import SwiftUI

/// Renders a rupee amount with the integer part in primary weight and the
/// decimal portion in a smaller, slightly muted size — so "₹1,234.56"
/// reads as a single number rather than two equally-weighted halves.
///
/// Direction = .in renders in green with a "+" prefix; .out renders in
/// primary text color, unprefixed. (No red — red would feel scolding.)
struct AmountText: View {
    let amount: Decimal
    let direction: Transaction.Direction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if direction == .in {
                Text("+")
                    .font(AppFont.rowAmount)
                    .foregroundStyle(AppColor.inflow)
            }
            Text(integerPart)
                .font(AppFont.rowAmount)
                .foregroundStyle(direction == .in ? AppColor.inflow : AppColor.textPrimary)
            Text(decimalPart)
                .font(AppFont.amountDecimal)
                .foregroundStyle(
                    direction == .in
                        ? AppColor.inflow.opacity(0.65)
                        : AppColor.textTertiary
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
    }

    private var formatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.maximumFractionDigits = 0
        return f
    }

    private var doubleValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }

    /// Integer portion with the rupee symbol prefixed: "₹1,234"
    private var integerPart: String {
        let intValue = Int(doubleValue)
        let formatted = formatter.string(from: NSNumber(value: intValue)) ?? "\(intValue)"
        return "₹\(formatted)"
    }

    /// Decimal portion: ".56" or empty when amount is whole.
    private var decimalPart: String {
        let cents = Int((doubleValue.truncatingRemainder(dividingBy: 1) * 100).rounded())
        if cents == 0 { return "" }
        return String(format: ".%02d", cents)
    }

    private var accessibilityValue: String {
        let sign = direction == .in ? "Received" : "Spent"
        return "\(sign) \(integerPart)\(decimalPart) rupees"
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
    }
    .padding()
}
