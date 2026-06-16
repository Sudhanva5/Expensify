import Foundation
import UserNotifications
import UIKit
import CoreLocation

/// Owns the silent-push lifecycle:
///   1. Asks the user for notification permission on first launch
///   2. Registers for remote notifications and ships the device token to the backend
///   3. When a silent push arrives, fetches GPS once and posts it to the backend
///   4. Renders visible pushes (budget alerts) as banners even when the app
///      is in the foreground — without the UNUserNotificationCenterDelegate
///      hook, iOS suppresses banners while the app is active.
final class PushService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushService()

    private override init() { super.init() }

    /// Called once from AppDelegate's didFinishLaunching. Asks for permission,
    /// then triggers APNs registration. Backend is told the token in
    /// didRegisterForRemoteNotificationsWithDeviceToken below.
    @MainActor
    func requestPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        // Wire ourselves up first so foreground notifications show banners.
        center.delegate = self
        do {
            // alert/sound/badge for future visible pushes (digest, budget breach).
            // Silent pushes don't strictly need any of these granted, but we ask
            // now so the user only sees one prompt.
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            #if DEBUG
            print("[PushService] notification permission granted: \(granted)")
            #endif
        } catch {
            #if DEBUG
            print("[PushService] notification permission error: \(error)")
            #endif
        }
        // Always register for remote — silent pushes work even if the user
        // declined visible notifications.
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Hand the APNs token to the backend so it knows where to deliver pushes.
    func handleDeviceToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        print("[PushService] APNs token: \(token)")
        #endif
        do {
            try await APIClient.shared.registerDevice(apnsToken: token)
        } catch {
            #if DEBUG
            print("[PushService] failed to register device with backend: \(error)")
            #endif
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Render visible notifications (budget alerts) as banners even when the
    /// app is in the foreground. Silent pushes never reach this method — they
    /// go through the AppDelegate background-fetch hook.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Process an incoming silent push. Called from
    /// application(_:didReceiveRemoteNotification:fetchCompletionHandler:).
    /// Returns the right UIBackgroundFetchResult so iOS knows whether to keep
    /// trusting us with future background time.
    ///
    /// Two-tier resolution against the new spend-time buffer:
    ///   1. Look up the closest buffer entry to the transaction's
    ///      `occurredAt`. If a sub-100m reading exists within ±10 min,
    ///      use that — gives us where the user actually was at spend-time,
    ///      not where they are NOW when this push happened to land.
    ///   2. If the buffer has nothing usable AND the spend is recent
    ///      (<2 min old), fall back to fetchOnce-now. This preserves the
    ///      old behavior for transactions where the push lands immediately
    ///      and the user is still at the merchant.
    ///   3. Otherwise abort — `noData` so iOS knows the push didn't
    ///      produce useful work but isn't a failure either. The row
    ///      stays awaiting; foreground catchup will retry from the
    ///      buffer next time the app opens.
    func handleSilentPush(userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard
            let kind = userInfo["kind"] as? String,
            kind == "request_location",
            let txId = userInfo["transactionId"] as? String
        else {
            #if DEBUG
            print("[PushService] silent push didn't match request_location shape: \(userInfo)")
            #endif
            return .noData
        }

        // Parse occurredAt from the payload. Server-side change
        // includes this as an ISO 8601 string. Push payloads that
        // pre-date the server change won't carry it; in that case we
        // fall back to "now" which preserves legacy behavior.
        let occurredAt: Date = {
            if let iso = userInfo["occurredAt"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: iso) { return d }
                let g = ISO8601DateFormatter()
                if let d = g.date(from: iso) { return d }
            }
            return Date()
        }()

        // Tier 1 — spend-time buffer match.
        if let entry = LocationService.shared.closestEntry(
            to: occurredAt,
            withinSeconds: 10 * 60,
            withMinAccuracy: 100
        ) {
            let city = await LocationService.reverseGeocode(
                CLLocation(latitude: entry.lat, longitude: entry.lng)
            )
            do {
                try await APIClient.shared.uploadLocation(
                    transactionId: txId,
                    latitude: entry.lat,
                    longitude: entry.lng,
                    city: city
                )
                #if DEBUG
                let delta = Int(abs(entry.timestamp.timeIntervalSince(occurredAt)))
                print("[PushService] buffer hit for \(txId) — entry \(Int(entry.accuracy))m, Δtime \(delta)s, city: \(city ?? "?")")
                #endif
                return .newData
            } catch {
                #if DEBUG
                print("[PushService] buffer-hit upload failed: \(error)")
                #endif
                return .failed
            }
        }

        // Tier 2 — fresh fetchOnce, but ONLY if the spend is recent
        // enough that "current location" is still meaningful.
        let spendAge = -occurredAt.timeIntervalSinceNow
        if spendAge > 2 * 60 {
            #if DEBUG
            print("[PushService] skip stale push for \(txId) — spend was \(Int(spendAge))s ago, no buffer hit")
            #endif
            return .noData
        }

        do {
            let location = try await LocationService.shared.fetchOnce()
            let city = await LocationService.reverseGeocode(location)
            try await APIClient.shared.uploadLocation(
                transactionId: txId,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                city: city
            )
            #if DEBUG
            print("[PushService] fetchOnce fallback for \(txId) — \(Int(location.horizontalAccuracy))m, city: \(city ?? "?")")
            #endif
            return .newData
        } catch {
            #if DEBUG
            print("[PushService] silent push handler failed: \(error)")
            #endif
            return .failed
        }
    }
}
