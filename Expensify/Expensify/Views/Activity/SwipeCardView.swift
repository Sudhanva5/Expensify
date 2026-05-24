import SwiftUI

/// One review card. Cred-inspired: merchant avatar + name on top, big
/// amount, then a single line of meta. Swipe right = "looks ok" (mark
/// resolved at the suggested category), swipe left = "needs tag" (queues
/// for the bulk tagging sheet).
///
/// Slack-style overlay: while the user is mid-swipe, a colored panel
/// reveals from the direction of the swipe with a big icon + label
/// telling them exactly what's about to happen. Greens up to the
/// threshold; flies off after.
struct SwipeCardView: View {
    enum SwipeDirection { case left, right }

    let item: ReviewItem
    let onSwipe: (SwipeDirection) -> Void

    @State private var offset: CGSize = .zero
    private let swipeThreshold: CGFloat = 100

    /// 0…1 how close we are to the threshold.
    private var dragProgress: CGFloat {
        min(1, abs(offset.width) / swipeThreshold)
    }

    var body: some View {
        ZStack {
            // Action overlays sit BEHIND the card and are revealed as the
            // card moves out from under them. Slack-style.
            actionOverlay(.left)   // left swipe = "needs tag"
            actionOverlay(.right)  // right swipe = "looks ok"

            cardContent
                .offset(offset)
                .rotationEffect(.degrees(Double(offset.width / 32)))
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
        }
    }

    // MARK: - Slack-style action overlays

    @ViewBuilder
    private func actionOverlay(_ side: SwipeDirection) -> some View {
        let isActive: Bool = (side == .left && offset.width < 0)
            || (side == .right && offset.width > 0)
        let progress = isActive ? dragProgress : 0
        let isLeft = side == .left

        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(isLeft ? AppColor.tap : AppColor.inflow)

            VStack(spacing: 14) {
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: isLeft ? "tag.fill" : "checkmark")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(isLeft ? "needs tag" : "looks ok")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isLeft ? .leading : .trailing)
            .padding(.horizontal, 40)
        }
        .frame(height: 360)
        .opacity(progress)
        .scaleEffect(0.94 + progress * 0.06)  // tiny scale-up as user commits
    }

    // MARK: - Card

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                MerchantAvatar(
                    merchantName: item.transaction.displayMerchant,
                    size: 56,
                    // Stable favicon source — bank's raw text, not the
                    // renameable display name.
                    brandKey: item.transaction.merchantRaw.isEmpty
                        ? item.transaction.vpa ?? ""
                        : item.transaction.merchantRaw
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.transaction.displayMerchant)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(2)
                    if let vpa = item.transaction.vpa {
                        // VPAs are diagnostic — keep them whole so the
                        // user can tell `q454981412@ybl` from
                        // `q454981410@ybl` at a glance.
                        Text(vpa)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            AmountText(amount: item.transaction.amountInr, direction: item.transaction.direction, size: 40)

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
        .shadow(color: .black.opacity(0.07), radius: 18, x: 0, y: 10)
    }

    // MARK: - Commit

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
