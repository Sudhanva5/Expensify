import Foundation
import CoreLocation

/// Coordinates "fill in location for transactions that are still awaiting".
/// Called from two places:
///   • LocationService delegate on every Significant Location Change wake-up
///   • AppDelegate's applicationDidBecomeActive → fetch one-shot, then backfill
///
/// Strategy (user's idea — zero extra battery cost):
///   1. Pull awaiting transactions with their occurred_at timestamps
///   2. For each, look up the SLC-history entry closest in time to occurred_at
///   3. Fall back to the freshly-supplied current location only when history
///      has no entries (e.g. first install)
///   4. POST per transaction. Backend is idempotent — already-fulfilled rows
///      are no-ops.
actor BackfillService {
    static let shared = BackfillService()

    private var inFlight = false

    /// Run the backfill. `currentFallback` is used only when the rolling
    /// history has no matching entry (rare — usually right after a fresh
    /// install before SLC has produced any updates).
    func backfillAwaiting(using currentFallback: CLLocation) async {
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

        for awaiting in awaitingList {
            // Pick the historical reading closest to occurredAt. This is the
            // killer move: location reflects WHERE you were AT the time of the
            // transaction, not where you happened to be when iOS finally got
            // around to waking the app.
            let location = LocationService.shared
                .bestLocationForTimestamp(awaiting.occurredAt)
                ?? currentFallback

            let city = await LocationService.reverseGeocode(location)

            do {
                try await APIClient.shared.uploadLocation(
                    transactionId: awaiting.id,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    city: city
                )
                #if DEBUG
                let delta = location.timestamp.timeIntervalSince(awaiting.occurredAt)
                print("[Backfill] uploaded for \(awaiting.id) — Δtime \(Int(delta))s")
                #endif
            } catch {
                #if DEBUG
                print("[Backfill] upload failed for \(awaiting.id): \(error)")
                #endif
            }
        }
    }

    /// Foreground convenience: grab the best-available location (cached if
    /// fresh, otherwise one-shot) and run the backfill. The cached read is
    /// the same one we'd use as a fallback inside backfillAwaiting itself.
    func backfillFromForeground() async {
        do {
            let loc = try await LocationService.shared.bestAvailableLocation()
            await backfillAwaiting(using: loc)
        } catch {
            #if DEBUG
            print("[Backfill] foreground fetch failed: \(error)")
            #endif
        }
    }
}
