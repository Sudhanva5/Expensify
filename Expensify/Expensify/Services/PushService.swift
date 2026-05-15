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

        do {
            // fetchOnce now WAITS for a sub-30m fix (up to 15s) instead of
            // grabbing the first cached cell-tower reading. Critical: we
            // only have ~30s of background time from the silent push, so
            // the timeout is sized to leave room for the upload that follows.
            let location = try await LocationService.shared.fetchOnce()
            let city = await LocationService.reverseGeocode(location)
            try await APIClient.shared.uploadLocation(
                transactionId: txId,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                city: city
            )
            #if DEBUG
            print("[PushService] uploaded \(Int(location.horizontalAccuracy))m fix for \(txId) — city: \(city ?? "?")")
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
