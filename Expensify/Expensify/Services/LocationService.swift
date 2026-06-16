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
    /// Kept for diagnostics (the Settings → activity feed could surface
    /// it later) — no longer used to assign locations to transactions.
    var locationHistory: [LocationTrace] {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let history = try? JSONDecoder().decode([LocationTrace].self, from: data) else {
            return []
        }
        return history
    }

    private static let historyKey = "expensify.locationHistory"
    private static let maxHistorySize = 500
    private static let maxHistoryAge: TimeInterval = 14 * 24 * 60 * 60

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

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // SLC + foreground bursts. We're not subscribing to standard updates
        // continuously, so backgroundLocationUpdates stays off.
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
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
    // PushService + BackfillService use when a silent push for an old
    // transaction finally lands. Returns nil rather than something stale
    // — null is better than wrong.

    private func appendToHistory(_ location: CLLocation) {
        var history = locationHistory
        history.append(LocationTrace(
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            timestamp: location.timestamp,
            accuracy: max(0, location.horizontalAccuracy)
        ))
        let cutoff = Date().addingTimeInterval(-Self.maxHistoryAge)
        history = history.filter { $0.timestamp >= cutoff }
        if history.count > Self.maxHistorySize {
            history = Array(history.suffix(Self.maxHistorySize))
        }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    /// Look up the buffer entry closest in time to `target`, gated by
    /// time window and accuracy. Returns nil when nothing qualifies —
    /// callers should treat that as "we don't know" and mark the
    /// transaction missed rather than guessing.
    func closestEntry(
        to target: Date,
        withinSeconds: TimeInterval = 10 * 60,
        withMinAccuracy: Double = 100
    ) -> LocationTrace? {
        let history = locationHistory
        guard !history.isEmpty else { return nil }
        let lo = target.addingTimeInterval(-withinSeconds)
        let hi = target.addingTimeInterval(withinSeconds)
        let candidates = history.filter {
            $0.timestamp >= lo
                && $0.timestamp <= hi
                && $0.accuracy > 0
                && $0.accuracy <= withMinAccuracy
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { a, b in
            abs(a.timestamp.timeIntervalSince(target))
                < abs(b.timestamp.timeIntervalSince(target))
        }
    }

    // MARK: - Opportunistic capture
    //
    // Triggered on every SLC wakeup (delegate `didUpdateLocations` when no
    // one-shot is in flight). Runs a brief high-accuracy fetchOnce so the
    // buffer carries a sub-30m entry for this location, NOT just the
    // 500m SLC reading.

    private func opportunisticCaptureIfNeeded() {
        lock.lock()
        let last = lastOpportunisticCaptureAt
        lock.unlock()

        if let last,
           Date().timeIntervalSince(last) < Self.opportunisticDebounceSeconds {
            #if DEBUG
            print("[LocationService] opportunistic skip — last capture \(Int(Date().timeIntervalSince(last)))s ago")
            #endif
            return
        }
        lock.lock()
        lastOpportunisticCaptureAt = Date()
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            do {
                // Shorter timeout than the silent-push handler — we just
                // want to upgrade the buffer; the background-task window
                // from SLC is finite and we share it with the appendToHistory
                // write that already happened.
                let _ = try await self.fetchOnce(
                    minimumAccuracyMeters: 30,
                    timeoutSeconds: 6
                )
                #if DEBUG
                print("[LocationService] opportunistic capture: appended to buffer")
                #endif
            } catch {
                #if DEBUG
                print("[LocationService] opportunistic capture failed (non-fatal): \(error)")
                #endif
            }
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

        // SLC tick with no in-flight one-shot. Kick off a brief
        // high-accuracy capture so the buffer entry for this location
        // gets upgraded from ~500m SLC to ~30m GPS. Debounced.
        opportunisticCaptureIfNeeded()
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
        }
    }
}

/// One entry in the rolling location history. Stored as JSON in UserDefaults.
///
/// `accuracy` is the `horizontalAccuracy` of the source CLLocation in meters.
/// SLC raw readings sit around 500m; foreground / opportunistic-fetchOnce
/// captures get down to 10-30m. The buffer-lookup helper filters on this
/// when deciding whether a stored entry is usable to ground a transaction.
struct LocationTrace: Codable {
    let lat: Double
    let lng: Double
    let timestamp: Date
    /// Decoded as 0 (i.e. "perfect") on legacy entries that pre-date this
    /// field. Old SLC-only entries are still useful as a coarse fallback
    /// when nothing better is available.
    var accuracy: Double = 0

    enum CodingKeys: String, CodingKey {
        case lat, lng, timestamp, accuracy
    }

    init(lat: Double, lng: Double, timestamp: Date, accuracy: Double) {
        self.lat = lat
        self.lng = lng
        self.timestamp = timestamp
        self.accuracy = accuracy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lat = try c.decode(Double.self, forKey: .lat)
        self.lng = try c.decode(Double.self, forKey: .lng)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.accuracy = (try? c.decode(Double.self, forKey: .accuracy)) ?? 0
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
