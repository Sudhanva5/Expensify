import Foundation
import Network

/// Watches iOS network state for interface changes (Wi-Fi ↔ cellular,
/// connected ↔ disconnected). HTTPClient subscribes so it can drop stale
/// TCP connections after a handoff, which is the #1 cause of "first
/// request after coming back online fails."
///
/// One shared instance, main-actor isolated so observers don't have to
/// worry about threading.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Called whenever the underlying network interface changes. Subscribers
    /// use this to invalidate any cached connections.
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "expensify.NetworkMonitor", qos: .utility)
    private var lastInterface: NWInterface.InterfaceType?
    private var hasReceivedInitialUpdate = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        // Pick the most preferred available interface (Wi-Fi over cellular
        // when both are present, mirroring what iOS does for routing).
        let current = path.availableInterfaces
            .first(where: { $0.type == .wifi })?
            .type
            ?? path.availableInterfaces.first?.type

        defer { lastInterface = current }

        // First update on app launch is just the current state — not a
        // "change" from anything. Skip the callback for that one.
        guard hasReceivedInitialUpdate else {
            hasReceivedInitialUpdate = true
            return
        }

        if current != lastInterface {
            #if DEBUG
            print("[NetworkMonitor] interface changed: \(String(describing: lastInterface)) → \(String(describing: current))")
            #endif
            onChange?()
        }
    }
}
