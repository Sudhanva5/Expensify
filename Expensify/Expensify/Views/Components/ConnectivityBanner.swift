import SwiftUI

/// Yellow banner shown at the top of a tab when the store can't reach the
/// backend. Stays visible while the auto-retry timer is running; user can
/// also tap "Retry now" to force an immediate attempt. Disappears as soon
/// as a fetch succeeds.
///
/// Apply via the `.connectivityBanner(store:)` view modifier on any tab's
/// content. The banner doesn't replace the existing data — it floats above
/// so the user can still scroll the last-known transactions while we
/// reconnect.
struct ConnectivityBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("Trouble connecting")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Showing last known data — retrying every 10 s")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onRetry) {
                Text("Retry now")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// Adds a floating connectivity banner at the top of the view whenever
    /// the store's connectionState is .failing. Last-known data stays
    /// visible underneath.
    func connectivityBanner(store: TransactionStore) -> some View {
        modifier(ConnectivityBannerModifier(store: store))
    }
}

private struct ConnectivityBannerModifier: ViewModifier {
    let store: TransactionStore

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            if case .failing(let message) = store.connectionState {
                ConnectivityBanner(message: message) {
                    Task { await store.refresh() }
                }
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.connectionState)
    }
}

#Preview {
    ConnectivityBanner(message: "The Internet connection appears to be offline.") { }
        .padding()
}
