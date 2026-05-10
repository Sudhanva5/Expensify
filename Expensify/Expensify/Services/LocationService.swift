import Foundation
import CoreLocation

/// One-shot location fetch wrapped around CLLocationManager. Designed to be
/// called from the silent-push handler — runs in well under the iOS 30-second
/// background-fetch window. Hundred-meter accuracy keeps battery cost low and
/// is plenty for "what city was I in" tagging.
final class LocationService: NSObject, @unchecked Sendable {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private let lock = NSLock()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Ask the user for location-while-using permission. Safe to call repeatedly.
    func requestPermission() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Fetch a single location reading. Throws if permission is denied or the
    /// system can't get a fix in time. Call this from the silent-push handler.
    func fetchOnce() async throws -> CLLocation {
        // Guard against concurrent callers — only one outstanding request.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
            lock.lock()
            if continuation != nil {
                lock.unlock()
                cont.resume(throwing: LocationError.alreadyInFlight)
                return
            }
            continuation = cont
            lock.unlock()

            // requestLocation() is the single-shot, lowest-power option.
            manager.requestLocation()
        }
    }

    /// Try to turn a CLLocation into a city/locality string. Returns nil if
    /// the geocoder can't resolve. CLGeocoder is rate-limited by Apple but
    /// generous for personal use.
    static func reverseGeocode(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.first?.locality ?? placemarks.first?.subAdministrativeArea
        } catch {
            return nil
        }
    }

    private func resolve(_ result: Result<CLLocation, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let loc):
            cont?.resume(returning: loc)
        case .failure(let err):
            cont?.resume(throwing: err)
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            resolve(.failure(LocationError.noLocation))
            return
        }
        resolve(.success(loc))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resolve(.failure(error))
    }
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
