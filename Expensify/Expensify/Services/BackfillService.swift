import Foundation
import CoreLocation

/// What woke the backfill. Only affects debouncing and log lines — the
/// resolution rules are identical, because "where was the user at
/// occurredAt" doesn't depend on why we're asking.
enum BackfillTrigger: String {
    /// The user opened the app. Always runs — it's user-initiated, and the
    /// user is entitled to see their rows resolve while they watch.
    case foreground
    /// A Significant Location Change woke us in the background. These fire
    /// on ~500m of movement and, crucially, are gated on *location*
    /// authorization rather than Background App Refresh — so this is the
    /// path that still works when Low Power Mode has killed silent pushes.
    case locationWake
}

/// Catches up `awaiting_location` transactions when the silent push failed
/// to wake the app (Low Power Mode, push throttling, etc.).
///
/// Called from `AppDelegate.applicationDidBecomeActive` AND from the
/// Significant Location Change delegate — an SLC wake is the only capture
/// path left when Low Power Mode / Background App Refresh off has stopped
/// iOS delivering silent pushes at all. Strategy favours the spend-time
/// buffer over a fresh fetchOnce:
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

    /// Minimum gap between two location-wake backfills. SLC can fire
    /// repeatedly while crossing cell towers (a train, a highway), and each
    /// run costs a round trip to /transactions/awaiting. Foreground runs are
    /// deliberately exempt.
    private static let locationWakeDebounce: TimeInterval = 2 * 60

    private var inFlight = false
    private var lastLocationWakeRunAt: Date?

    /// Catch up every row still awaiting a location.
    ///
    /// Called from `applicationDidBecomeActive` and from the SLC delegate.
    func backfillAwaiting(trigger: BackfillTrigger) async {
        if inFlight { return }

        if trigger == .locationWake, let last = lastLocationWakeRunAt,
           Date().timeIntervalSince(last) < Self.locationWakeDebounce {
            #if DEBUG
            print("[Backfill] locationWake skipped — ran \(Int(Date().timeIntervalSince(last)))s ago")
            #endif
            return
        }
        if trigger == .locationWake { lastLocationWakeRunAt = Date() }

        inFlight = true
        defer { inFlight = false }

        let awaitingList: [APIClient.AwaitingTransaction]
        do {
            awaitingList = try await APIClient.shared.fetchAwaitingLocationTransactions()
        } catch {
            #if DEBUG
            print("[Backfill] \(trigger.rawValue): fetch awaiting failed: \(error)")
            #endif
            return
        }
        if awaitingList.isEmpty {
            #if DEBUG
            print("[Backfill] \(trigger.rawValue): nothing awaiting")
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
            if let entry = LocationService.shared.bestEntry(for: awaiting.occurredAt) {
                await upload(entry: entry, for: awaiting.id, occurredAt: awaiting.occurredAt)
                bufferHits += 1
            } else if awaiting.occurredAt >= Date().addingTimeInterval(-Self.recentWindow) {
                stillNeedingNow.append(awaiting)
            }
        }

        #if DEBUG
        print("[Backfill] \(trigger.rawValue): \(awaitingList.count) awaiting, \(bufferHits) resolved from buffer, \(stillNeedingNow.count) recent rows need a fresh fix")
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
