import Foundation
import CoreLocation

/// Two responsibilities, one CLLocationManager:
///
///   • One-shot fetch (`fetchOnce`) — used by the silent-push handler and by
///     the foreground backfill. Triggers `requestLocation()`, which is the
///     lowest-power one-shot option (~10s, hundred-meter accuracy).
///
///   • Significant Location Changes monitoring (`startSignificantChangeMonitoring`) —
///     subscribed once at launch. iOS wakes the app whenever the device moves
///     ~500m using cell-tower / wifi-cache (no GPS spin-up). Apple guarantees
///     this works in Low Power Mode. Every wake-up triggers a backfill of any
///     transactions whose location is still 'awaiting'.
///
/// Both flows funnel through one CLLocationManagerDelegate. We disambiguate
/// by whether there's an active one-shot continuation — if yes, resolve it;
/// otherwise it's an SLC tick and we fire the backfill task.
final class LocationService: NSObject, @unchecked Sendable {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private let lock = NSLock()

    /// Rolling movement log built from SLC updates. Zero extra battery cost —
    /// we only persist what iOS already hands us. Used to match awaiting
    /// transactions to the location closest in time to when they happened.
    var locationHistory: [LocationTrace] {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let history = try? JSONDecoder().decode([LocationTrace].self, from: data) else {
            return []
        }
        return history
    }

    /// Most recent SLC reading, derived from the history.
    var cachedLocation: CLLocation? {
        locationHistory.last.map { trace in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: trace.lat, longitude: trace.lng),
                altitude: 0,
                horizontalAccuracy: 500,
                verticalAccuracy: -1,
                timestamp: trace.timestamp
            )
        }
    }

    /// Return the historical location closest in time to the given target.
    /// Returns nil if the history is empty. There's no "too far in time"
    /// threshold — even an old match is usually more useful than the
    /// current location for a transaction that happened hours ago.
    func bestLocationForTimestamp(_ target: Date) -> CLLocation? {
        let history = locationHistory
        guard !history.isEmpty else { return nil }

        var best: LocationTrace?
        var smallestDelta: TimeInterval = .infinity
        for trace in history {
            let delta = abs(trace.timestamp.timeIntervalSince(target))
            if delta < smallestDelta {
                smallestDelta = delta
                best = trace
            }
        }

        guard let match = best else { return nil }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: match.lat, longitude: match.lng),
            altitude: 0,
            horizontalAccuracy: 500,
            verticalAccuracy: -1,
            timestamp: match.timestamp
        )
    }

    private static let historyKey = "expensify.locationHistory"
    private static let maxHistorySize = 200
    private static let maxHistoryAge: TimeInterval = 14 * 24 * 60 * 60  // 14 days

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Critical: with Background Modes -> Location enabled, iOS will let us
        // run during SLC wake-ups even when LPM is on.
        manager.allowsBackgroundLocationUpdates = false  // we don't need continuous
        manager.pausesLocationUpdatesAutomatically = true
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Ask for Always permission. iOS will prompt for "When In Use" first
    /// (you tap Allow While Using) and later upgrade to Always via a follow-up
    /// prompt or via the Settings nudge. Always is required to receive SLC
    /// wake-ups in the background, which is the whole point.
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

    /// One-shot fetch. Errors if permission is denied or the OS can't get a
    /// fix in time. Used by silent push + foreground backfill paths.
    func fetchOnce() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
            lock.lock()
            if continuation != nil {
                lock.unlock()
                cont.resume(throwing: LocationError.alreadyInFlight)
                return
            }
            continuation = cont
            lock.unlock()
            manager.requestLocation()
        }
    }

    /// Cached if reasonably fresh, otherwise a one-shot fetch. This is the
    /// most battery-friendly read for backfill flows — SLC keeps the cache
    /// warm during normal movement.
    func bestAvailableLocation(maxAgeSeconds: TimeInterval = 15 * 60) async throws -> CLLocation {
        if let cached = cachedLocation,
           cached.timestamp.timeIntervalSinceNow > -maxAgeSeconds {
            return cached
        }
        return try await fetchOnce()
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

    // MARK: - Private

    private func appendToHistory(_ location: CLLocation) {
        var history = locationHistory
        history.append(LocationTrace(
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            timestamp: location.timestamp
        ))

        // Drop entries older than the retention window
        let cutoff = Date().addingTimeInterval(-Self.maxHistoryAge)
        history = history.filter { $0.timestamp >= cutoff }

        // Cap size — keep the most recent N
        if history.count > Self.maxHistorySize {
            history = Array(history.suffix(Self.maxHistorySize))
        }

        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func resolveOneShot(_ result: Result<CLLocation, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let loc): cont?.resume(returning: loc)
        case .failure(let err): cont?.resume(throwing: err)
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // Always append to the rolling movement log. This is the foundation
        // for "match awaiting transactions to where you were at that time."
        appendToHistory(loc)

        lock.lock()
        let waitingOneShot = continuation != nil
        lock.unlock()

        if waitingOneShot {
            // Resolve the in-flight fetchOnce() call.
            resolveOneShot(.success(loc))
        } else {
            // Background wake from SLC — backfill any awaiting transactions.
            Task { await BackfillService.shared.backfillAwaiting(using: loc) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Only resolve a one-shot fetch with the error — SLC errors are
        // typically transient and not worth propagating.
        lock.lock()
        let waitingOneShot = continuation != nil
        lock.unlock()
        if waitingOneShot {
            resolveOneShot(.failure(error))
        } else {
            #if DEBUG
            print("[LocationService] SLC delegate error (ignored): \(error)")
            #endif
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // When the user grants When-In-Use, follow up by requesting Always so
        // SLC can run in the background. iOS shows the "Change to Always
        // Allow?" prompt the next time the app is foregrounded.
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            // Safe to start SLC — Apple ignores it if permission isn't right.
            startSignificantChangeMonitoring()
        }
    }
}

/// One entry in the rolling location history. Stored as JSON in UserDefaults.
struct LocationTrace: Codable {
    let lat: Double
    let lng: Double
    let timestamp: Date
}

enum LocationError: Error, LocalizedError {
    case alreadyInFlight
    case noLocation

    var errorDescription: String? {
        switch self {
        case .alreadyInFlight: return "Another location request is already running"
        case .noLocation: return "No location returned"
        }
    }
}
