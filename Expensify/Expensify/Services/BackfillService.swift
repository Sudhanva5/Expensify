import Foundation
import CoreLocation

/// Catches up `awaiting_location` transactions when the silent push failed
/// to wake the app (Low Power Mode, push throttling, app force-quit, etc.).
///
/// Called from `AppDelegate.applicationDidBecomeActive`. Strategy:
///   1. Take a fresh, accuracy-bounded location reading via `fetchOnce`
///      (which now WAITS for sub-30m GPS instead of grabbing the first
///      stale cell-tower estimate).
///   2. Pull the awaiting list.
///   3. For each row whose `occurredAt` is within `recentWindow`, post
///      the fresh location. Anything older than that is left awaiting —
///      we used to fill it in from SLC history but those readings were
///      ~500m-accurate and were the main source of the bad Places tags.
///      Old awaiting rows just sit in the review queue without a map;
///      the user can tag them manually.
///
/// SLC wake-ups no longer trigger backfill. Their readings are too coarse.
/// They still keep the location subsystem warm so a foreground `fetchOnce`
/// resolves faster.
actor BackfillService {
    static let shared = BackfillService()

    /// Only attach a fresh foreground location to transactions that
    /// occurred within this window. Beyond it, the user has almost
    /// certainly moved, so guessing is worse than no location.
    private static let recentWindow: TimeInterval = 5 * 60

    private var inFlight = false

    /// Foreground catchup. Fired from `applicationDidBecomeActive`.
    func backfillFromForeground() async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }

        let awaitingList: [APIClient.AwaitingTransaction]
        do {
            awaitingList = try await APIClient.shared.fetchAwaitingLocationTransactions()
        } catch {
            #if DEBUG
            print("[Backfill] fetch awaiting failed: \(error)")
            #endif
            return
        }
        if awaitingList.isEmpty {
            #if DEBUG
            print("[Backfill] nothing awaiting")
            #endif
            return
        }

        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        let recent = awaitingList.filter { $0.occurredAt >= cutoff }
        if recent.isEmpty {
            #if DEBUG
            print("[Backfill] \(awaitingList.count) awaiting rows, none within \(Int(Self.recentWindow))s window — leaving for manual review")
            #endif
            return
        }

        let location: CLLocation
        do {
            // Reuses the new accuracy-bounded fetcher: waits up to ~15s
            // for a sub-30m fix, falls back to the best reading seen.
            location = try await LocationService.shared.fetchOnce()
        } catch {
            #if DEBUG
            print("[Backfill] foreground fetchOnce failed: \(error)")
            #endif
            return
        }

        #if DEBUG
        print("[Backfill] attaching \(Int(location.horizontalAccuracy))m fix to \(recent.count) recent awaiting row(s)")
        #endif

        let city = await LocationService.reverseGeocode(location)

        for awaiting in recent {
            do {
                try await APIClient.shared.uploadLocation(
                    transactionId: awaiting.id,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    city: city
                )
                #if DEBUG
                let delta = Int(-awaiting.occurredAt.timeIntervalSinceNow)
                print("[Backfill] uploaded for \(awaiting.id) — Δtime \(delta)s")
                #endif
            } catch {
                #if DEBUG
                print("[Backfill] upload failed for \(awaiting.id): \(error)")
                #endif
            }
        }
    }
}
