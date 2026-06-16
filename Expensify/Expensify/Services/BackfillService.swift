import Foundation
import CoreLocation

/// Catches up `awaiting_location` transactions when the silent push failed
/// to wake the app (Low Power Mode, push throttling, etc.).
///
/// Called from `AppDelegate.applicationDidBecomeActive`. Strategy now
/// favours the spend-time buffer over a fresh fetchOnce:
///
///   1. Pull the awaiting list (each row carries its own occurredAt).
///   2. For each row, look up `LocationService.closestEntry(to: occurredAt)`
///      — the buffer entry from when the user actually spent the money,
///      not where they happen to be sitting right now.
///   3. If the buffer has nothing usable AND the spend happened in the
///      last 5 min, take ONE fresh fetchOnce and use it for every recent
///      row. Cheap and right for the "I just spent and re-opened the app"
///      case.
///   4. Older rows with no buffer hit get LEFT awaiting. Tagging a
///      6-hour-old hotel charge with "user's current location at the
///      airport" is exactly the bug this whole refactor exists to fix.
actor BackfillService {
    static let shared = BackfillService()

    /// Only fall back to a NOW fetchOnce for transactions this recent.
    /// Older rows depend entirely on the spend-time buffer.
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

        // Pass 1: spend-time buffer lookup for EVERY awaiting row,
        // regardless of age. The buffer carries up to 14 days of
        // history; if the user opened the app and we have an entry
        // from when the spend happened, we can ground it.
        var bufferHits = 0
        var stillNeedingNow: [APIClient.AwaitingTransaction] = []
        for awaiting in awaitingList {
            if let entry = LocationService.shared.closestEntry(
                to: awaiting.occurredAt,
                withinSeconds: 10 * 60,
                withMinAccuracy: 100
            ) {
                await upload(entry: entry, for: awaiting.id, occurredAt: awaiting.occurredAt)
                bufferHits += 1
            } else if awaiting.occurredAt >= Date().addingTimeInterval(-Self.recentWindow) {
                stillNeedingNow.append(awaiting)
            }
        }

        #if DEBUG
        print("[Backfill] \(awaitingList.count) awaiting, \(bufferHits) resolved from buffer, \(stillNeedingNow.count) recent rows need a fresh fix")
        #endif

        // Pass 2: one fresh fetchOnce for any recent rows the buffer
        // didn't cover. Conservative — old rows without buffer hits
        // are left for manual review.
        guard !stillNeedingNow.isEmpty else { return }
        let location: CLLocation
        do {
            location = try await LocationService.shared.fetchOnce()
        } catch {
            #if DEBUG
            print("[Backfill] foreground fetchOnce failed: \(error)")
            #endif
            return
        }
        let city = await LocationService.reverseGeocode(location)
        for awaiting in stillNeedingNow {
            do {
                try await APIClient.shared.uploadLocation(
                    transactionId: awaiting.id,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    city: city
                )
                #if DEBUG
                let delta = Int(-awaiting.occurredAt.timeIntervalSinceNow)
                print("[Backfill] fetchOnce uploaded for \(awaiting.id) — Δtime \(delta)s, \(Int(location.horizontalAccuracy))m")
                #endif
            } catch {
                #if DEBUG
                print("[Backfill] upload failed for \(awaiting.id): \(error)")
                #endif
            }
        }
    }

    /// Upload a single buffer entry. Pulled out so the spend-time and
    /// fetchOnce paths use identical wire shape.
    private func upload(
        entry: LocationTrace,
        for transactionId: String,
        occurredAt: Date
    ) async {
        let city = await LocationService.reverseGeocode(
            CLLocation(latitude: entry.lat, longitude: entry.lng)
        )
        do {
            try await APIClient.shared.uploadLocation(
                transactionId: transactionId,
                latitude: entry.lat,
                longitude: entry.lng,
                city: city
            )
            #if DEBUG
            let delta = Int(abs(entry.timestamp.timeIntervalSince(occurredAt)))
            print("[Backfill] buffer uploaded for \(transactionId) — \(Int(entry.accuracy))m, Δtime \(delta)s")
            #endif
        } catch {
            #if DEBUG
            print("[Backfill] upload failed for \(transactionId): \(error)")
            #endif
        }
    }
}
