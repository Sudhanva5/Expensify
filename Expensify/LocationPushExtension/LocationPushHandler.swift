import CoreLocation
import Foundation

/// Answers `apns-push-type: location` pushes — the one wake path that still
/// works when Low Power Mode has forced Background App Refresh off.
///
/// iOS drops `content-available` pushes outright in that state, so
/// `PushService.handleSilentPush` never runs and every outflow strands at
/// `awaiting` until the 24h sweep calls it `missed`. A location push is
/// delivered here instead, in a separate process, gated on location
/// authorization rather than Background App Refresh, and it works with the
/// app terminated.
///
/// Resolution mirrors the in-app handler exactly, because the question is the
/// same one — "where was the user at `occurredAt`?", not "where is the phone
/// now":
///
///   1. **Spend-time buffer.** Closest entry within ±10 min of `occurredAt`
///      with accuracy ≤100m, read from the App Group container the app
///      writes. This is why the buffer had to move out of
///      `UserDefaults.standard` — a separate process cannot see that.
///   2. **Fresh fix**, but only when the spend is under 2 minutes old, so
///      "now" is still a truthful answer for "then".
///   3. **Nothing.** Complete without uploading; the row stays `awaiting`
///      and the SLC-wake backfill grounds it later. A wrong location is
///      worse than a missing one.
///
/// Budget discipline: the completion handler is called exactly once on every
/// path, including termination. An extension that returns without calling it
/// teaches iOS to stop waking us.
final class LocationPushHandler: NSObject, CLLocationPushServiceExtension {

    /// Hard ceiling on the fresh-fix attempt. Deliberately shorter than the
    /// app's 15s one-shot: this process can be terminated at any moment and a
    /// half-finished GPS lock is worth less than a clean completion.
    private static let fixTimeout: TimeInterval = 8

    /// Worst accuracy we'll accept from a fresh fix. `requestLocation` can
    /// hand back a cell-tower estimate hundreds of metres wide; uploading one
    /// of those would put the transaction in the wrong neighbourhood. Past
    /// this bound we report nothing and let the SLC-wake backfill try later,
    /// which is the same "null beats wrong" rule the rest of the pipeline
    /// follows.
    private static let maxAcceptableAccuracy: Double = 150

    private var completion: (() -> Void)?
    private var fix: LocationFix?
    private var work: Task<Void, Never>?

    func didReceiveLocationPushPayload(
        _ payload: [String: Any],
        completion: @escaping () -> Void
    ) {
        self.completion = completion

        guard
            let kind = payload["kind"] as? String, kind == "request_location",
            let transactionId = payload["transactionId"] as? String
        else {
            SharedLocationStore.recordWake(.badPayload)
            finish()
            return
        }

        let occurredAt = Self.parseOccurredAt(payload["occurredAt"] as? String)

        work = Task { [weak self] in
            guard let self else { return }
            await self.resolve(transactionId: transactionId, occurredAt: occurredAt)
            self.finish()
        }
    }

    func serviceExtensionWillTerminate() {
        // Last word before iOS reclaims the process. Drop the in-flight work
        // and hand the completion back so this wake counts as finished
        // rather than hung.
        work?.cancel()
        fix?.cancel()
        finish()
    }

    // MARK: - Resolution

    private func resolve(transactionId: String, occurredAt: Date) async {
        // Tier 1 — the buffer already knows where the user was when they paid.
        if let entry = SharedLocationStore.closestEntry(
            to: occurredAt,
            withinSeconds: 10 * 60,
            withMinAccuracy: 100
        ) {
            SharedLocationStore.recordWake(.bufferHit)
            await upload(transactionId: transactionId, lat: entry.lat, lng: entry.lng)
            return
        }

        // Tier 2 — no buffer entry, but the spend is recent enough that the
        // phone's current position is still an honest answer.
        let spendAge = -occurredAt.timeIntervalSinceNow
        guard spendAge <= 2 * 60 else {
            SharedLocationStore.recordWake(.declined)
            return
        }

        let fix = LocationFix()
        self.fix = fix
        guard let location = await fix.current(
            maxAcceptableAccuracy: Self.maxAcceptableAccuracy,
            timeout: Self.fixTimeout
        ) else {
            SharedLocationStore.recordWake(.declined)
            return
        }

        SharedLocationStore.recordWake(.freshFix)
        // Feed the buffer as well: this fix is also evidence for any *other*
        // row that lands near this timestamp, and in Low Power Mode the app
        // itself may not run for hours.
        SharedLocationStore.append(location)
        await upload(
            transactionId: transactionId,
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude
        )
    }

    /// No reverse geocoding here, unlike the in-app path. `city` is optional
    /// on the wire and the backend doesn't persist it, so spending part of a
    /// short budget on a `CLGeocoder` round trip buys nothing.
    private func upload(transactionId: String, lat: Double, lng: Double) async {
        do {
            try await LocationUploadClient.upload(
                transactionId: transactionId,
                latitude: lat,
                longitude: lng
            )
        } catch {
            // One attempt only. The row stays `awaiting`; the SLC-wake
            // backfill will retry from the buffer.
            NSLog("[LocationPush] upload failed for %@: %@", transactionId, String(describing: error))
        }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        completion()
    }

    private static func parseOccurredAt(_ iso: String?) -> Date {
        guard let iso else { return Date() }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        return ISO8601DateFormatter().date(from: iso) ?? Date()
    }
}

/// Minimal one-shot location request for the extension.
///
/// Deliberately NOT a copy of `LocationService.fetchOnce`. That one streams
/// updates via `startUpdatingLocation()` and leans on
/// `allowsBackgroundLocationUpdates = true` to keep the stream alive while
/// backgrounded — and an app extension cannot set that flag: it requires a
/// `location` entry in UIBackgroundModes, which an appex has no business
/// declaring, and setting it without one traps at runtime.
///
/// So this uses `requestLocation()`, the call Apple's own location-push
/// template uses, and applies the quality bar afterwards instead of waiting
/// for a better reading that a streamed session would have provided.
private final class LocationFix: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var maxAccuracy: Double = 150
    private var timeoutTask: Task<Void, Never>?
    private let lock = NSLock()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func current(maxAcceptableAccuracy: Double, timeout: TimeInterval) async -> CLLocation? {
        maxAccuracy = maxAcceptableAccuracy
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            lock.lock()
            continuation = cont
            lock.unlock()

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // Give up rather than hang. The caller's completion handler is
                // what tells iOS this wake finished cleanly, and an extension
                // that never completes stops getting woken.
                self?.resume(with: nil)
            }

            manager.requestLocation()
        }
    }

    func cancel() {
        resume(with: nil)
    }

    private func resume(with location: CLLocation?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return }
        timeoutTask?.cancel()
        cont.resume(returning: location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else {
            resume(with: nil)
            return
        }

        // Same trap as the app: the first reading of any session is often a
        // cached cell-tower fix from minutes ago, i.e. where the user was
        // before they arrived.
        if -loc.timestamp.timeIntervalSinceNow > 30 {
            resume(with: nil)
            return
        }

        resume(with: loc.horizontalAccuracy <= maxAccuracy ? loc : nil)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[LocationPush] location error: %@", String(describing: error))
        resume(with: nil)
    }
}
