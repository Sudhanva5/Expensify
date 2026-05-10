import SwiftUI

/// Third tab. Swipe stack while items remain → tagging list once everything
/// has been swiped (and at least one was flagged "needs tag"). Empty state
/// when no items pending review.
struct ActivityView: View {
    @Binding var showSettings: Bool
    @Environment(TransactionStore.self) private var store

    @State private var queue: [ReviewItem] = []
    @State private var pendingTags: [PendingTag] = []
    @State private var showTaggingList = false

    private var totalCount: Int { store.reviewItems.count }
    private var swipedCount: Int { totalCount - queue.count }

    var body: some View {
        NavigationStack {
            Group {
                if store.loadError != nil {
                    ErrorView(message: store.loadError ?? "") {
                        Task { await store.refresh() }
                    }
                } else if store.isLoading && store.transactions.isEmpty {
                    LoadingView()
                } else if queue.isEmpty && pendingTags.isEmpty {
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
            .task {
                if store.transactions.isEmpty { await store.refresh() }
                syncQueueFromStore()
            }
            .onChange(of: store.transactions) { _, _ in
                syncQueueFromStore()
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showTaggingList) {
                TaggingListView(
                    pending: $pendingTags,
                    onUpdate: applyTaggingChanges,
                    onCancel: cancelTagging
                )
            }
        }
    }

    @ViewBuilder
    private var cardStack: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("\(min(swipedCount + 1, totalCount)) of \(totalCount) to review")
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

    private var visibleCards: [ReviewItem] {
        Array(queue.prefix(3))
    }

    private func syncQueueFromStore() {
        // Only re-seed if the queue is empty (don't disrupt mid-swipe state).
        if queue.isEmpty && pendingTags.isEmpty {
            queue = store.reviewItems
        }
    }

    private func handleSwipe(item: ReviewItem, direction: SwipeCardView.SwipeDirection) {
        queue.removeAll { $0.id == item.id }

        if direction == .left {
            pendingTags.append(PendingTag(item: item))
        }

        if queue.isEmpty && !pendingTags.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                showTaggingList = true
            }
        }
    }

    private func applyTaggingChanges() {
        // V1: just clear local state. Wiring this to the backend is the next
        // step (POST /transactions/:id/category) — for now you can confirm
        // visually that the tagging list flow works.
        pendingTags.removeAll()
        showTaggingList = false
    }

    private func cancelTagging() {
        showTaggingList = false
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't load review queue")
                .font(.subheadline.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    @Previewable @State var s = false
    return ActivityView(showSettings: $s)
        .environment(TransactionStore())
}
