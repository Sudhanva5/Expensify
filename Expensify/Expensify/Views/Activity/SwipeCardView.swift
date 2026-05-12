import SwiftUI

/// One swipeable card in the review stack. Owns its own drag offset.
/// Calls `onSwipe(.left)` if the user swipes past the threshold to the left
/// ("needs tag"), or `.right` for "looks ok".
struct SwipeCardView: View {
    enum SwipeDirection { case left, right }

    let item: ReviewItem
    let onSwipe: (SwipeDirection) -> Void

    @State private var offset: CGSize = .zero
    @State private var isDragging = false

    private let swipeThreshold: CGFloat = 100

    var body: some View {
        cardContent
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width / 20)))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = value.translation
                        isDragging = true
                    }
                    .onEnded { value in
                        let horizontal = value.translation.width
                        if horizontal < -swipeThreshold {
                            commitSwipe(.left)
                        } else if horizontal > swipeThreshold {
                            commitSwipe(.right)
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                                offset = .zero
                            }
                            isDragging = false
                        }
                    }
            )
            .overlay(alignment: .topLeading) { hintLabel("Needs tag", visibleAt: -1) }
            .overlay(alignment: .topTrailing) { hintLabel("Looks ok", visibleAt: 1) }
    }

    // MARK: - Content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Top: amount + merchant
            VStack(alignment: .leading, spacing: 4) {
                Text(amountString)
                    .font(.system(size: 44, weight: .bold))
                Text(item.transaction.displayMerchant)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                if let vpa = item.transaction.vpa {
                    Text(vpa)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Suggestion block
            if let suggested = item.suggestedCategory {
                HStack(spacing: 8) {
                    Image(systemName: suggested.symbolName)
                        .foregroundStyle(suggested.tint)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggested.shortName)
                            .font(.subheadline.weight(.semibold))
                        if let detail = item.suggestionDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.orange)
                    Text("No suggestion — needs your tag")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            // Bottom: timestamp + location + instrument
            HStack(spacing: 8) {
                Text(timeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.transaction.locationStatus != .notApplicable {
                    LocationChip(
                        label: item.transaction.locationLabel,
                        status: item.transaction.locationStatus,
                        latitude: item.transaction.locationLat,
                        longitude: item.transaction.locationLng,
                        merchantLabel: item.transaction.displayMerchant
                    )
                }
                Spacer()
                Text(instrumentString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .frame(height: 360)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
    }

    // MARK: - Helpers

    private func commitSwipe(_ dir: SwipeDirection) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            offset = CGSize(width: dir == .left ? -600 : 600, height: 0)
        }
        // Haptic feedback
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()

        // Tell parent after the animation has had a moment to play
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onSwipe(dir)
        }
    }

    /// The corner hint label (Needs tag / Looks ok). visibleAt = -1 means
    /// shows when swiping left, +1 when swiping right.
    private func hintLabel(_ text: String, visibleAt: Double) -> some View {
        let progress = min(1, abs(offset.width) / swipeThreshold)
        let isMatchingDirection =
            (visibleAt < 0 && offset.width < 0) || (visibleAt > 0 && offset.width > 0)
        let opacity = isMatchingDirection ? Double(progress) : 0

        let color: Color = visibleAt < 0 ? .orange : .green
        return Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color)
            .clipShape(Capsule())
            .padding(20)
            .opacity(opacity)
    }

    private var amountString: String {
        let value = NSDecimalNumber(decimal: item.transaction.amountInr).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = (value.truncatingRemainder(dividingBy: 1) == 0) ? 0 : 2
        return "₹\(f.string(from: NSNumber(value: value)) ?? String(value))"
    }

    private var timeString: String {
        let df = DateFormatter()
        df.dateFormat = "EEE, d MMM · h:mm a"
        return df.string(from: item.transaction.occurredAt)
    }

    private var instrumentString: String {
        let inst = item.transaction.instrument
        if inst.hasPrefix("card_") {
            return "Card ••\(inst.replacingOccurrences(of: "card_", with: ""))"
        } else if inst.hasPrefix("account_") {
            return "Account ••\(inst.replacingOccurrences(of: "account_", with: ""))"
        }
        return inst
    }
}

#Preview {
    SwipeCardView(item: MockData.reviewItems.first!) { _ in }
        .padding()
}
