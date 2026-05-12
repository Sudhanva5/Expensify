import SwiftUI

/// One review card. Cred-inspired: merchant avatar + name on top, big
/// amount, then a single line of meta. Swipe right = "looks ok" (mark
/// resolved at the suggested category), swipe left = "needs tag" (queues
/// for the bulk tagging sheet).
struct SwipeCardView: View {
    enum SwipeDirection { case left, right }

    let item: ReviewItem
    let onSwipe: (SwipeDirection) -> Void

    @State private var offset: CGSize = .zero
    private let swipeThreshold: CGFloat = 100

    var body: some View {
        cardContent
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width / 24)))
            .gesture(
                DragGesture()
                    .onChanged { value in offset = value.translation }
                    .onEnded { value in
                        let h = value.translation.width
                        if h < -swipeThreshold {
                            commitSwipe(.left)
                        } else if h > swipeThreshold {
                            commitSwipe(.right)
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                offset = .zero
                            }
                        }
                    }
            )
            .overlay(alignment: .topLeading) { hintLabel("needs tag", direction: -1) }
            .overlay(alignment: .topTrailing) { hintLabel("looks ok", direction: 1) }
    }

    // MARK: - Card

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                MerchantAvatar(merchantName: item.transaction.displayMerchant, size: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.transaction.displayMerchant)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(2)
                    if let vpa = item.transaction.vpa {
                        Text(vpa)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(amountIntegerString)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
                Text(amountDecimalString)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AppColor.textTertiary)
            }

            Divider().background(AppColor.hairline)

            VStack(alignment: .leading, spacing: 6) {
                if let suggested = item.suggestedCategory {
                    HStack(spacing: 8) {
                        Image(systemName: suggested.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColor.textSecondary)
                        Text("looks like \(suggested.shortName.lowercased())")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColor.textPrimary)
                        if let detail = item.suggestionDetail {
                            Text("· \(detail.lowercased())")
                                .font(AppFont.caption)
                                .foregroundStyle(AppColor.textTertiary)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 13))
                        Text("no suggestion — needs your tag")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(AppColor.textSecondary)
                }

                HStack(spacing: 6) {
                    Text(timeString)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                    if item.transaction.locationStatus != .notApplicable {
                        Text("·")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                        LocationChip(
                            label: item.transaction.locationCity ?? item.transaction.locationLabel,
                            status: item.transaction.locationStatus,
                            latitude: item.transaction.locationLat,
                            longitude: item.transaction.locationLng,
                            merchantLabel: item.transaction.displayMerchant,
                            compact: true
                        )
                    }
                    Spacer()
                    Text(instrumentString)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .frame(height: 360)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppColor.hairline.opacity(0.7), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 16, x: 0, y: 8)
    }

    // MARK: - Swipe affordances

    private func hintLabel(_ text: String, direction: Double) -> some View {
        let progress = min(1, abs(offset.width) / swipeThreshold)
        let isMatching = (direction < 0 && offset.width < 0) || (direction > 0 && offset.width > 0)
        let opacity = isMatching ? Double(progress) : 0
        let bg: Color = direction < 0 ? AppColor.textSecondary : AppColor.inflow

        return Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(bg)
            .clipShape(Capsule())
            .padding(22)
            .opacity(opacity)
    }

    private func commitSwipe(_ dir: SwipeDirection) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            offset = CGSize(width: dir == .left ? -700 : 700, height: 0)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            onSwipe(dir)
        }
    }

    // MARK: - Strings

    private var doubleAmount: Double {
        NSDecimalNumber(decimal: item.transaction.amountInr).doubleValue
    }

    private var amountIntegerString: String {
        let intValue = Int(doubleAmount)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return "₹\(f.string(from: NSNumber(value: intValue)) ?? "\(intValue)")"
    }

    private var amountDecimalString: String {
        let cents = Int((doubleAmount.truncatingRemainder(dividingBy: 1) * 100).rounded())
        return cents == 0 ? "" : String(format: ".%02d", cents)
    }

    private var timeString: String {
        let df = DateFormatter()
        df.dateFormat = "EEE, d MMM · h:mm a"
        return df.string(from: item.transaction.occurredAt).lowercased()
    }

    private var instrumentString: String {
        InstrumentLabel.display(for: item.transaction.instrument).lowercased()
    }
}

#Preview {
    SwipeCardView(item: MockData.reviewItems.first!) { _ in }
        .padding()
        .background(AppColor.canvas)
}
