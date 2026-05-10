import SwiftUI

/// Third tab. Shows the swipe stack while items remain; presents the tagging
/// list as a sheet once everything has been swiped (and at least one was
/// flagged "needs tag"). Empty state when no items pending review.
struct ActivityView: View {
    @Binding var showSettings: Bool

    @State private var queue: [ReviewItem] = MockData.reviewItems
    @State private var pendingTags: [PendingTag] = []
    @State private var showTaggingList = false

    private var totalCount: Int { MockData.reviewItems.count }
    private var swipedCount: Int { totalCount - queue.count }

    var body: some View {
        NavigationStack {
            Group {
                if queue.isEmpty && pendingTags.isEmpty {
                    EmptyStateView()
                } else {
                    cardStack
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AvatarButton(initials: "SA") { showSettings = true }
                }
            }
            .sheet(isPresented: $showTaggingList) {
                TaggingListView(
                    pending: $pendingTags,
                    onUpdate: applyTaggingChanges,
                    onCancel: cancelTagging
                )
            }
        }
    }

    // MARK: - Card stack

    @ViewBuilder
    private var cardStack: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("\(swipedCount + 1) of \(totalCount) to review")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            ZStack {
                ForEach(visibleCards.reversed()) { item in
                    let depth = queue.firstIndex(of: item) ?? 0
                    SwipeCardView(item: item) { dir in
                        handleSwipe(item: item, direction: dir)
                    }
                    .scaleEffect(1 - CGFloat(depth) * 0.04)
                    .offset(y: CGFloat(depth) * 8)
                    .zIndex(Double(visibleCards.count - depth))
                }
            }
            .padding(.horizontal, 16)

            HStack {
                Label("Needs tag", systemImage: "arrow.left")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Label("Looks ok", systemImage: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Spacer()
        }
    }

    /// Top three cards in the stack — gives a peek of what's underneath.
    private var visibleCards: [ReviewItem] {
        Array(queue.prefix(3))
    }

    // MARK: - Actions

    private func handleSwipe(item: ReviewItem, direction: SwipeCardView.SwipeDirection) {
        // Remove the swiped item from the queue
        queue.removeAll { $0.id == item.id }

        // Left = needs tag → goes into pending list for bulk tagging
        if direction == .left {
            pendingTags.append(PendingTag(item: item))
        }

        // When the queue is empty AND we have items to tag, present the sheet
        if queue.isEmpty && !pendingTags.isEmpty {
            // Tiny delay so the last card's exit animation gets to play
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                showTaggingList = true
            }
        }
    }

    private func applyTaggingChanges() {
        // V1: just clear the pending list. In V2 this hits the backend.
        // Real implementation: POST /transactions/:id/category for each row.
        pendingTags.removeAll()
        showTaggingList = false
    }

    private func cancelTagging() {
        // Cancelled — items stay in the pending list. User can swipe again or
        // re-open the sheet later. For now, just dismiss.
        showTaggingList = false
    }
}

#Preview {
    @Previewable @State var s = false
    return ActivityView(showSettings: $s)
}
