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

    /// Budget for the fresh-fix attempt. Was 8s, which never once produced a
    /// usable fix — the first real test of this path (a café spend, phone
    /// indoors on a table, GPS cold) came back empty and the row stranded.
    /// A cold lock routinely needs 10s+, and the extension's own window is
    /// wider than that, so the old ceiling was self-defeating: it guaranteed
    /// a clean completion with nothing in it.
    private static let fixTimeout: TimeInterval = 18

    /// Worst accuracy we'll accept from a fresh fix. `requestLocation` can
    /// hand back a cell-tower estimate hundreds of metres wide; uploading one
    /// of those would put the transaction in the wrong neighbourhood. Past
    /// this bound we report nothing and let the SLC-wake backfill try later,
    /// which is the same "null beats wrong" rule the rest of the pipeline
    /// follows.
    ///
    /// 200m rather than 150m: the Places auto-rename downstream applies its
    /// own 30m strict radius, so a coarse fix can never invent a merchant —
    /// it only ever costs precision on the map pin, and a roughly-right pin
    /// beats a blank row.
    private static let maxAcceptableAccuracy: Double = 200

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
            SharedLocationStore.recordWake(.badPayload, authorization: authorizationLabel())
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
        if let entry = SharedLocationStore.bestEntry(for: occurredAt) {
            SharedLocationStore.recordWake(
                .bufferHit,
                authorization: authorizationLabel(),
                accuracy: entry.accuracy
            )
            await upload(transactionId: transactionId, lat: entry.lat, lng: entry.lng)
            return
        }

        // Tier 2 — no buffer entry, but the spend is recent enough that the
        // phone's current position is still an honest answer.
        let spendAge = -occurredAt.timeIntervalSinceNow
        guard spendAge <= 2 * 60 else {
            SharedLocationStore.recordWake(.declinedStaleSpend, authorization: authorizationLabel())
            return
        }

        let fix = LocationFix()
        self.fix = fix
        let attempt = await fix.current(
            maxAcceptableAccuracy: Self.maxAcceptableAccuracy,
            timeout: Self.fixTimeout
        )
        guard let location = attempt.location else {
            // Distinguish "CoreLocation gave us nothing" from "it gave us
            // something unusable" — the first points at authorization or
            // budget, the second at the accuracy bar. Both looked identical
            // in the log that shipped yesterday.
            SharedLocationStore.recordWake(
                attempt.rejectedAccuracy == nil ? .declinedNoFix : .declinedCoarse,
                authorization: authorizationLabel(),
                accuracy: attempt.rejectedAccuracy
            )
            return
        }

        SharedLocationStore.recordWake(
            .freshFix,
            authorization: authorizationLabel(),
            accuracy: location.horizontalAccuracy
        )
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

    /// Authorization from inside the extension. The app's view can differ in
    /// the way that matters: "while using" leaves a backgrounded appex with
    /// no location at all, which is invisible from the app side.
    private func authorizationLabel() -> String {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "while using"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private static func parseOccurredAt(_ iso: String?) -> Date {
        guard let iso else { return Date() }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        return ISO8601DateFormatter().date(from: iso) ?? Date()
    }
}

/// One-shot location request for the extension, reporting why it failed.
///
/// Deliberately NOT a copy of `LocationService.fetchOnce`. That one streams
/// updates via `startUpdatingLocation()` and leans on
/// `allowsBackgroundLocationUpdates = true` to keep the stream alive while
/// backgrounded — and an app extension cannot set that flag: it requires a
/// `location` entry in UIBackgroundModes, which an appex has no business
/// declaring, and setting it without one traps at runtime.
///
/// So this uses `requestLocation()`, the call Apple's own location-push
/// template uses, and retries it within the budget. One shot was not enough:
/// the first reading of a cold session is often a wide cell-tower estimate,
/// and returning that single sample as the verdict is what made this path
/// fail on its first real use.
private final class LocationFix: NSObject, CLLocationManagerDelegate {

    /// Outcome of an attempt. `rejectedAccuracy` is set when readings did
    /// arrive but none cleared the bar — that distinction is the difference
    /// between "authorization/budget problem" and "accuracy problem", which
    /// a bare nil could not express.
    struct Attempt {
        let location: CLLocation?
        let rejectedAccuracy: Double?
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Attempt, Never>?
    private var maxAccuracy: Double = 200
    private var bestRejected: CLLocation?
    private var timeoutTask: Task<Void, Never>?
    private let lock = NSLock()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func current(maxAcceptableAccuracy: Double, timeout: TimeInterval) async -> Attempt {
        maxAccuracy = maxAcceptableAccuracy
        return await withCheckedContinuation { (cont: CheckedContinuation<Attempt, Never>) in
            lock.lock()
            continuation = cont
            lock.unlock()

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // Give up rather than hang: the caller's completion handler is
                // what tells iOS this wake finished cleanly, and an extension
                // that never completes stops getting woken.
                self?.finish(with: nil)
            }

            manager.requestLocation()
        }
    }

    func cancel() {
        finish(with: nil)
    }

    /// Resolve once. `accepted` nil means we failed; the rejected-accuracy
    /// field still carries the best thing we saw so the log can say which
    /// kind of failure it was.
    private func finish(with accepted: CLLocation?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let rejected = bestRejected
        lock.unlock()
        guard let cont else { return }
        timeoutTask?.cancel()
        cont.resume(returning: Attempt(
            location: accepted,
            rejectedAccuracy: accepted == nil ? rejected?.horizontalAccuracy : nil
        ))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else {
            manager.requestLocation()
            return
        }

        // Same trap as the app: the first reading of a session is often a
        // cached cell-tower fix from minutes ago, i.e. where the user was
        // before they arrived. Ask again rather than accept it.
        if -loc.timestamp.timeIntervalSinceNow > 30 {
            manager.requestLocation()
            return
        }

        if loc.horizontalAccuracy <= maxAccuracy {
            finish(with: loc)
            return
        }

        // Too coarse: remember it as evidence for the log, then ask again.
        // GPS sharpens over the first several seconds, so the second or third
        // reading inside the budget is frequently the one that clears the bar.
        lock.lock()
        if bestRejected == nil || loc.horizontalAccuracy < bestRejected!.horizontalAccuracy {
            bestRejected = loc
        }
        lock.unlock()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A denial is terminal — retrying would just burn the budget. Anything
        // else is transient often enough to be worth another ask.
        if let clError = error as? CLError, clError.code == .denied {
            NSLog("[LocationPush] location denied to extension")
            finish(with: nil)
            return
        }
        NSLog("[LocationPush] location error: %@", String(describing: error))
        manager.requestLocation()
    }
}
