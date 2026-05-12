import Foundation
import CoreLocation

/// Coordinates "fill in location for transactions that are still awaiting".
/// Called from two places:
///   • LocationService delegate on every Significant Location Change wake-up
///   • AppDelegate's applicationDidBecomeActive → fetch one-shot, then backfill
///
/// Idempotent on the backend side: the /transactions/:id/location endpoint
/// no-ops if the row is already fulfilled or not_applicable.
actor BackfillService {
    static let shared = BackfillService()

    private var inFlight = false

    /// Pull the list of awaiting transaction IDs from the backend and POST
    /// the provided location for each. Reverse-geocodes once if possible.
    func backfillAwaiting(using location: CLLocation) async {
        if inFlight { return }            // simple guard against overlapping ticks
        inFlight = true
        defer { inFlight = false }

        do {
            let ids = try await APIClient.shared.fetchAwaitingLocationTransactionIds()
            if ids.isEmpty {
                #if DEBUG
                print("[Backfill] nothing awaiting")
                #endif
                return
            }

            let city = await LocationService.reverseGeocode(location)

            for id in ids {
                do {
                    try await APIClient.shared.uploadLocation(
                        transactionId: id,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        city: city
                    )
                    #if DEBUG
                    print("[Backfill] uploaded for \(id)")
                    #endif
                } catch {
                    #if DEBUG
                    print("[Backfill] upload failed for \(id): \(error)")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            print("[Backfill] fetch awaiting failed: \(error)")
            #endif
        }
    }

    /// Foreground convenience: grab the best-available location (cached if
    /// fresh, otherwise one-shot) and run the backfill.
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
