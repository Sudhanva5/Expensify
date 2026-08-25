import Foundation
import CoreLocation

/// One CLLocationManager, two responsibilities:
///
///   • `fetchOnce(...)` — accuracy-bounded one-shot for the silent-push wake
///     and the foreground catchup. Streams CLLocation updates, **waits** for
///     a reading whose `horizontalAccuracy` is good enough, then stops.
///     Replaces the old `requestLocation()` call which returned the first
///     (typically cached / cell-tower) reading and stopped — that's the
///     fix for the 500m-typical-error problem we were seeing in production.
///
///   • Significant Location Changes (`startSignificantChangeMonitoring`) —
///     subscribed once at launch. iOS wakes the app whenever the device
///     moves ~500m via cell-tower / Wi-Fi cache. Still useful for keeping
///     the app warm; we no longer use SLC readings to tag transactions
///     because their ~500m accuracy was generating confidently-wrong
///     Places matches.
///
/// Both flows funnel through the same `CLLocationManagerDelegate`. We
/// disambiguate by `oneShotState` — when set, the reading flows into the
/// accuracy-wait state machine; otherwise it's an SLC tick we ignore
/// (apart from appending to the history log for diagnostic value).
final class LocationService: NSObject, @unchecked Sendable {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var oneShotState: OneShotState?

    /// Rolling movement log built from every CLLocation that reaches us.
    /// Storage lives in `SharedLocationStore` (App Group) so the
    /// location-push extension queries the same buffer this app fills.
    var locationHistory: [LocationTrace] { SharedLocationStore.load() }

    /// Don't fire opportunistic fetchOnce more than once per this many
    /// seconds. Caps battery cost when SLC fires rapidly (crossing Wi-Fi
    /// boundaries, train through cell towers). 60s means worst-case
    /// ~1440 GPS bursts/day, but in practice SLC + this debounce yields
    /// 10-30/day for a normal user.
    private static let opportunisticDebounceSeconds: TimeInterval = 60
    private var lastOpportunisticCaptureAt: Date?

    /// Maximum age of a CLLocation we'll accept as "real" — anything older
    /// is almost certainly a cached reading iOS is returning before GPS
    /// has spun up. The pattern we observed: iOS hands back a 5-minute-old
    /// 800m-accurate cell-tower fix as the first update of a stream, then
    /// follows up 5 seconds later with a fresh 12m GPS fix.
    private static let staleReadingThreshold: TimeInterval = 30

    /// Location-push monitoring is started from two places — launch and the
    /// authorization-change delegate — because either can be the first
    /// moment it's legal. Starting it twice is pointless and iOS answers the
    /// duplicate with an error, so it's gated to once per process.
    private var locationPushMonitoringStarted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest

        // MUST be true. `fetchOnce` drives `startUpdatingLocation()`, and its
        // single most important caller is the silent-push handler — which by
        // definition runs while the app is backgrounded. Continuous updates
        // are suspended in the background unless this is set, so the old
        // `false` meant Tier-2 fetchOnce routinely timed out with
        // `.noLocation` during exactly the wake it exists to serve. (The
        // `location` UIBackgroundModes entry this requires is already in
        // Info.plist; setting this without it would trap at runtime.)
        //
        // This does NOT mean we track continuously: `fetchOnce` stops the
        // stream the moment it has an accurate-enough reading, and nothing
        // else calls `startUpdatingLocation`. Background cost stays bounded
        // by the one-shot's own timeout.
        manager.allowsBackgroundLocationUpdates = true

        // Auto-pause is a power optimisation for long-running navigation-style
        // sessions. Our sessions are 6-15 second bursts; iOS pausing one
        // mid-flight just starves the one-shot of readings.
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Ask for Always permission. iOS will prompt for "When In Use" first
    /// (you tap Allow While Using) and later upgrade to Always via a follow-up
    /// prompt or via the Settings nudge. Always is required to receive SLC
    /// wake-ups in the background, which is what keeps the location subsystem
    /// "warm" between transactions.
    func requestAlwaysPermission() {
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Subscribe to significant-location updates. Idempotent — calling
    /// multiple times is safe; iOS coalesces.
    func startSignificantChangeMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            #if DEBUG
            print("[LocationService] SLC not available on this device")
            #endif
            return
        }
        manager.startMonitoringSignificantLocationChanges()
    }

    /// Subscribe to APNs **location pushes** and hand the resulting token to
    /// the backend.
    ///
    /// This is the wake path that survives Low Power Mode. iOS refuses to
    /// deliver `content-available` pushes when Background App Refresh is off
    /// — which Low Power Mode forces — so the silent-push handler simply
    /// never runs, and every outflow strands at `awaiting` until the 24h
    /// sweep marks it `missed`. A location push is delivered to the
    /// location-push *extension* instead, gated on location authorization,
    /// and works with the app terminated.
    ///
    /// Two traps: the token this hands back is NOT the APNs token (a
    /// location push sent to the regular token fails), and the call needs the
    /// `com.apple.developer.location.push` entitlement — without it the
    /// completion returns an error and we keep running on silent pushes
    /// alone, which is the pre-existing behaviour rather than a regression.
    func startLocationPushMonitoring() {
        lock.lock()
        let alreadyStarted = locationPushMonitoringStarted
        locationPushMonitoringStarted = true
        lock.unlock()
        if alreadyStarted { return }

        manager.startMonitoringLocationPushes { [weak self] tokenData, error in
            if let error {
                #if DEBUG
                print("[LocationService] location-push monitoring failed: \(error)")
                #endif
                // Let a later authorization change retry — the usual cause is
                // asking before authorization existed.
                self?.lock.lock()
                self?.locationPushMonitoringStarted = false
                self?.lock.unlock()
                return
            }
            guard let tokenData else { return }
            let token = tokenData.map { String(format: "%02x", $0) }.joined()
            Task { await PushService.shared.handleLocationPushToken(token) }
        }
    }

    /// Accuracy-bounded one-shot fetch.
    ///
    /// Starts streaming CLLocation updates with `kCLLocationAccuracyBest`,
    /// rejects stale-cached readings, keeps the best reading so far, and
    /// resolves either:
    ///   • As soon as a fresh reading hits `minimumAccuracyMeters`, OR
    ///   • After `timeoutSeconds`, returning the best reading we saw, OR
    ///   • With `.noLocation` if no reading at all arrived within the window
    ///
    /// Why this beats `requestLocation()`: the old API stops after the
    /// first reading. The first reading is almost always a stale Wi-Fi /
    /// cell-tower estimate iOS had cached — typical accuracy 500m–3km.
    /// GPS satellites take ~5s to lock from cold; we have to keep
    /// listening past that point.
    func fetchOnce(
        minimumAccuracyMeters: Double = 30,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> CLLocation {
        // Boot a fresh continuation. If one's already in-flight, fail it
        // first so we don't leak.
        if let stale = takeOneShot() {
            stale.timeoutTask?.cancel()
            stale.continuation.resume(throwing: LocationError.alreadyInFlight)
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
            // Schedule the timeout race in parallel with the location stream.
            let timeoutTask = Task { [weak self] in
                let ns = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                self?.resolveOneShotWithBestOrError()
            }

            lock.lock()
            oneShotState = OneShotState(
                continuation: cont,
                minimumAccuracy: minimumAccuracyMeters,
                startTime: Date(),
                bestReading: nil,
                timeoutTask: timeoutTask
            )
            lock.unlock()

            // Best accuracy → spin up GPS hardware. Stream stops in
            // `considerForOneShot` once we hit the accuracy bar.
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.startUpdatingLocation()

            #if DEBUG
            print("[LocationService] fetchOnce started — target \(minimumAccuracyMeters)m, timeout \(Int(timeoutSeconds))s")
            #endif
        }
    }

    /// Try to turn a CLLocation into a city/locality string.
    static func reverseGeocode(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.first?.locality ?? placemarks.first?.subAdministrativeArea
        } catch {
            return nil
        }
    }

    // MARK: - One-shot state machine

    private struct OneShotState {
        let continuation: CheckedContinuation<CLLocation, Error>
        let minimumAccuracy: Double
        let startTime: Date
        var bestReading: CLLocation?
        var timeoutTask: Task<Void, Never>?
    }

    /// Process an incoming reading against the in-flight one-shot.
    /// Returns true when the reading was "consumed" by the one-shot path
    /// (whether accepted, rejected as stale, or held as best-so-far) —
    /// which tells the delegate not to treat it as an SLC tick.
    private func considerForOneShot(_ location: CLLocation) -> Bool {
        lock.lock()
        guard var state = oneShotState else {
            lock.unlock()
            return false
        }

        // Reject readings older than the staleness threshold. iOS hands
        // back a cached pre-GPS fix as the first update of every stream.
        let age = -location.timestamp.timeIntervalSinceNow
        if age > Self.staleReadingThreshold {
            #if DEBUG
            print("[LocationService] discard stale reading — age \(Int(age))s, acc \(Int(location.horizontalAccuracy))m")
            #endif
            lock.unlock()
            return true
        }

        // Negative horizontalAccuracy means the reading is invalid.
        if location.horizontalAccuracy < 0 {
            lock.unlock()
            return true
        }

        // Track best-so-far so the timeout path always has a useful fallback.
        if let prev = state.bestReading {
            if location.horizontalAccuracy < prev.horizontalAccuracy {
                state.bestReading = location
                oneShotState = state
            }
        } else {
            state.bestReading = location
            oneShotState = state
        }

        // Hit the target → resolve, stop streaming.
        if location.horizontalAccuracy <= state.minimumAccuracy {
            oneShotState = nil
            let cont = state.continuation
            let timeoutTask = state.timeoutTask
            lock.unlock()
            timeoutTask?.cancel()
            manager.stopUpdatingLocation()
            #if DEBUG
            print("[LocationService] fetchOnce resolved — \(Int(location.horizontalAccuracy))m after \(Int(-state.startTime.timeIntervalSinceNow))s")
            #endif
            cont.resume(returning: location)
            return true
        }

        #if DEBUG
        print("[LocationService] reading kept — \(Int(location.horizontalAccuracy))m (waiting for ≤\(Int(state.minimumAccuracy))m)")
        #endif
        lock.unlock()
        return true
    }

    /// Timeout fallback — return the best reading we saw, or fail.
    private func resolveOneShotWithBestOrError() {
        lock.lock()
        guard let state = oneShotState else {
            lock.unlock()
            return
        }
        oneShotState = nil
        lock.unlock()
        manager.stopUpdatingLocation()

        if let best = state.bestReading {
            #if DEBUG
            print("[LocationService] fetchOnce timed out — using best-seen \(Int(best.horizontalAccuracy))m fix")
            #endif
            state.continuation.resume(returning: best)
        } else {
            #if DEBUG
            print("[LocationService] fetchOnce timed out — no readings received")
            #endif
            state.continuation.resume(throwing: LocationError.noLocation)
        }
    }

    private func takeOneShot() -> OneShotState? {
        lock.lock()
        let state = oneShotState
        oneShotState = nil
        lock.unlock()
        return state
    }

    // MARK: - History buffer
    //
    // Rolling timestamped buffer of every CLLocation the app sees, used to
    // ground a transaction's location to where the user actually was at
    // spend-time — NOT where they are now. SLC alone fires ~500m-accurate
    // readings; the opportunistic-fetchOnce on each SLC wake upgrades the
    // buffer to sub-30m for ~95% of entries.
    //
    // `closestEntry(to:withinSeconds:withMinAccuracy:)` is the lookup that
    // PushService, BackfillService and the location-push extension use when
    // a wake for an old transaction finally lands. Returns nil rather than
    // something stale — null is better than wrong.
    //
    // Storage itself lives in SharedLocationStore, in the App Group
    // container, because the extension is a different process and can't
    // read this one's UserDefaults.standard.

    private func appendToHistory(_ location: CLLocation) {
        SharedLocationStore.append(location)
    }

    /// Look up the buffer entry closest in time to `target`. Thin passthrough
    /// to `SharedLocationStore` — kept because the app's call sites
    /// (PushService, BackfillService) reach for the service, while the
    /// extension talks to the store directly.
    func closestEntry(
        to target: Date,
        withinSeconds: TimeInterval = 10 * 60,
        withMinAccuracy: Double = 100
    ) -> LocationTrace? {
        SharedLocationStore.closestEntry(
            to: target,
            withinSeconds: withinSeconds,
            withMinAccuracy: withMinAccuracy
        )
    }

    // MARK: - Opportunistic capture
    //
    // Triggered on every SLC wakeup (delegate `didUpdateLocations` when no
    // one-shot is in flight). Runs a brief high-accuracy fetchOnce so the
    // buffer carries a sub-30m entry for this location, NOT just the
    // 500m SLC reading.

    /// Put a fresh, accurate entry in the spend-time buffer *now*, and wait
    /// for it to land.
    ///
    /// The buffer's whole job is to answer "where was the user at
    /// `occurredAt`?", but it was only ever written from SLC ticks — which
    /// fire on ~500m of movement. Sit still in a café and the buffer has
    /// nothing anywhere near your spend, so both the silent-push Tier-1
    /// lookup and the foreground backfill miss and the row strands.
    ///
    /// Two callers, one implementation: foregrounding (the user very often
    /// opens the app within a couple of minutes of paying) and an SLC wake
    /// (upgrades that tick's ~500m reading to a ~30m one). They differ only
    /// in how long they're willing to wait — a background wake shares its
    /// window with the backfill that runs next.
    ///
    /// Failures are swallowed — this is best-effort buffer warming, never a
    /// blocking step.
    func captureIntoBufferIfNeeded(timeoutSeconds: TimeInterval = 8) async {
        lock.lock()
        let last = lastOpportunisticCaptureAt
        lock.unlock()

        if let last,
           Date().timeIntervalSince(last) < Self.opportunisticDebounceSeconds {
            #if DEBUG
            print("[LocationService] buffer capture skipped — last capture \(Int(Date().timeIntervalSince(last)))s ago")
            #endif
            return
        }
        lock.lock()
        lastOpportunisticCaptureAt = Date()
        lock.unlock()

        do {
            _ = try await fetchOnce(minimumAccuracyMeters: 30, timeoutSeconds: timeoutSeconds)
            #if DEBUG
            print("[LocationService] buffer warmed")
            #endif
        } catch {
            #if DEBUG
            print("[LocationService] buffer capture failed (non-fatal): \(error)")
            #endif
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // Always append — buffer carries SLC + fetchOnce entries side-by-
        // side. Spend-time lookups filter on accuracy so coarse SLC
        // readings are only used when nothing better is available.
        appendToHistory(loc)

        // If a one-shot is in flight, route the reading through the
        // accuracy state machine. The one-shot is the higher-priority
        // consumer; opportunistic capture would no-op anyway.
        if considerForOneShot(loc) { return }

        // SLC tick with no in-flight one-shot. Two jobs, in this order:
        //
        //   1. Upgrade this location's buffer entry from the ~500m SLC
        //      reading to a ~30m GPS one. Debounced.
        //   2. Run the awaiting-backfill.
        //
        // Step 2 is what makes location capture survive Low Power Mode.
        // iOS drops `content-available` pushes outright when Background App
        // Refresh is off, so the silent-push wake never happens and rows sit
        // `awaiting` until the 24h sweep calls them `missed`. An SLC wake is
        // a *location* wake — gated on location authorization, not on
        // Background App Refresh — so it still arrives, and the buffer it
        // just warmed lets us ground the spend at the time it happened.
        //
        // Ordering is load-bearing: the capture must land in the buffer
        // before the backfill reads it, which is why this awaits rather
        // than firing both off in parallel.
        Task { [weak self] in
            // Shorter timeout than the foreground path — the background
            // window from an SLC wake is finite and shared with the
            // backfill's network round trips.
            await self?.captureIntoBufferIfNeeded(timeoutSeconds: 6)
            await BackfillService.shared.backfillAwaiting(trigger: .locationWake)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lock.lock()
        let inFlight = oneShotState != nil
        lock.unlock()
        if inFlight {
            // Don't fail immediately — iOS often emits transient errors
            // before delivering a usable reading. Let the timeout decide.
            #if DEBUG
            print("[LocationService] one-shot delegate error (will let timeout decide): \(error)")
            #endif
        } else {
            #if DEBUG
            print("[LocationService] SLC delegate error (ignored): \(error)")
            #endif
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            startSignificantChangeMonitoring()
            // Location pushes need location authorization to be granted
            // before iOS will mint a token, so this is the earliest honest
            // moment to ask — and it re-runs on every upgrade of the
            // authorization, which is exactly when a previous attempt would
            // have failed.
            startLocationPushMonitoring()
        }
    }
}

enum LocationError: Error, LocalizedError {
    case alreadyInFlight
    case noLocation

    var errorDescription: String? {
        switch self {
        case .alreadyInFlight: return "Another location request is already running"
        case .noLocation: return "No location returned within the time budget"
        }
    }
}
