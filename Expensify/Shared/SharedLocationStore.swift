import Foundation
import CoreLocation

/// The spend-time location buffer, in the one place both processes can reach.
///
/// Why this file exists: the location-push extension runs as a **separate
/// process with its own container**. It cannot see
/// `UserDefaults.standard`, which is where the buffer used to live — so an
/// extension reading it would find an empty history every single time, fall
/// through to "take a fix now", and tag transactions with wherever the phone
/// happened to be when APNs delivered. That is precisely the bug the buffer
/// was built to prevent.
///
/// So the storage moves to the App Group suite, and both targets compile this
/// file. `LocationService` keeps ownership of *capturing* locations;
/// this type owns *storing and querying* them.
enum SharedLocationStore {

    /// App Group shared by the app and the location-push extension. Must
    /// match the `com.apple.security.application-groups` entitlement in
    /// BOTH targets — a typo here doesn't fail loudly, it just silently
    /// hands back a private container, so treat this as one constant with
    /// two consumers rather than a string to retype.
    static let appGroupID = "group.NCPUDP.Expensifyy"

    static let historyKey = "expensify.locationHistory"

    /// Buffer retention. Long, because a location push or an SLC wake may
    /// arrive days after the spend it refers to and the lookup is bounded by
    /// time-to-`occurredAt` anyway, not by entry age.
    static let maxHistoryAge: TimeInterval = 14 * 24 * 60 * 60
    static let maxHistorySize = 500

    /// The shared suite, or `.standard` if the App Group is missing.
    ///
    /// The fallback is deliberate: without it, a signing/entitlement mishap
    /// would take the *app's* own buffer down with it and break location
    /// capture wholesale. Degrading to a private container costs the
    /// extension its tier-1 lookups — bad, but survivable, and visible in
    /// Diagnostics.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// True when the App Group is actually wired up. Surfaced in Diagnostics
    /// so a broken entitlement is a visible fact rather than a mystery
    /// degradation.
    static var isSharedContainerAvailable: Bool {
        UserDefaults(suiteName: appGroupID) != nil
    }

    // MARK: - Read / write

    static func load() -> [LocationTrace] {
        guard let data = defaults.data(forKey: historyKey),
              let history = try? JSONDecoder().decode([LocationTrace].self, from: data) else {
            return []
        }
        return history
    }

    static func append(_ trace: LocationTrace) {
        var history = load()
        history.append(trace)
        let cutoff = Date().addingTimeInterval(-maxHistoryAge)
        history = history.filter { $0.timestamp >= cutoff }
        if history.count > maxHistorySize {
            history = Array(history.suffix(maxHistorySize))
        }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    static func append(_ location: CLLocation) {
        append(LocationTrace(
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            timestamp: location.timestamp,
            accuracy: max(0, location.horizontalAccuracy)
        ))
    }

    /// Look up the buffer entry closest in time to `target`, gated by time
    /// window and accuracy. Returns nil when nothing qualifies — callers
    /// treat that as "we don't know", which is honest, where "here's where
    /// the phone is now" would be a confident lie.
    static func closestEntry(
        to target: Date,
        withinSeconds: TimeInterval = 10 * 60,
        withMinAccuracy: Double = 100
    ) -> LocationTrace? {
        let history = load()
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

    // MARK: - Location-push wake log
    //
    // The extension runs in a process with no UI, no debugger attached, and
    // no reachable console once the phone is off the cable — so "did the
    // location push actually wake us?" was unanswerable from either side.
    // The push succeeds at APNs whether or not iOS delivers it, and the
    // extension declining for a good reason (spend too old, no buffer entry)
    // looks identical to never having run. That ambiguity is what made the
    // original Low Power Mode failure take a day to find.
    //
    // So every wake stamps the shared container. Cheap, and it turns the
    // Diagnostics screen into a real answer.

    static let wakeCountKey = "expensify.locationPushWakeCount"
    static let lastWakeAtKey = "expensify.locationPushLastWakeAt"
    static let lastWakeOutcomeKey = "expensify.locationPushLastOutcome"

    /// What a location-push wake managed to do. Recorded even when the
    /// answer is "nothing" — a decline is a successful wake, and telling
    /// the two apart is the entire point of this log.
    enum WakeOutcome: String {
        /// Resolved from the spend-time buffer — the good path.
        case bufferHit = "buffer hit"
        /// Took a fresh fix because the spend was recent.
        case freshFix = "fresh fix"
        /// Woke, but the spend was too old to answer honestly and the buffer
        /// had nothing near it. Correct behaviour, not a failure.
        case declined = "declined — no usable location"
        /// Payload wasn't a location request. Should never happen in practice.
        case badPayload = "unrecognised payload"
    }

    static func recordWake(_ outcome: WakeOutcome) {
        let d = defaults
        d.set(d.integer(forKey: wakeCountKey) + 1, forKey: wakeCountKey)
        d.set(Date(), forKey: lastWakeAtKey)
        d.set(outcome.rawValue, forKey: lastWakeOutcomeKey)
    }

    static var wakeCount: Int { defaults.integer(forKey: wakeCountKey) }
    static var lastWakeAt: Date? { defaults.object(forKey: lastWakeAtKey) as? Date }
    static var lastWakeOutcome: String? { defaults.string(forKey: lastWakeOutcomeKey) }

    // MARK: - Migration

    /// Move a pre-App-Group buffer into the shared suite, once.
    ///
    /// Called from the app (the extension must never migrate — it would race
    /// the app and it has no legacy container of its own to read). Copies
    /// only when the shared suite is still empty, so a second run can't
    /// clobber entries the extension has since written. The legacy key is
    /// cleared afterwards so there's exactly one buffer of record.
    static func migrateFromStandardIfNeeded() {
        guard isSharedContainerAvailable else { return }
        guard defaults.data(forKey: historyKey) == nil else { return }
        guard let legacy = UserDefaults.standard.data(forKey: historyKey) else { return }

        defaults.set(legacy, forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
        #if DEBUG
        let count = load().count
        print("[SharedLocationStore] migrated \(count) buffer entries into the App Group")
        #endif
    }
}

/// One entry in the rolling location history. Stored as JSON in the App
/// Group's UserDefaults, written by the app and by the location-push
/// extension.
///
/// `accuracy` is the `horizontalAccuracy` of the source CLLocation in meters.
/// SLC raw readings sit around 500m; foreground / opportunistic-fetchOnce
/// captures get down to 10-30m. `closestEntry` filters on this when deciding
/// whether a stored entry is usable to ground a transaction.
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
