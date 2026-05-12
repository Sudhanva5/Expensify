import UIKit

/// Bridge between SwiftUI's @main App struct and UIKit's UIApplicationDelegate.
/// Owns: APNs token + silent-push callbacks, Significant Location Change
/// monitoring lifecycle, and the foreground-backfill nudge that catches up
/// any 'awaiting' transactions when the user opens the app.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Pre-warm the connection to Railway as the very first thing. Opens
        // TCP+TLS to the host so the user's first /transactions fetch is
        // instant. Fire and forget.
        Task { await HTTPClient.shared.warmup(baseURL: Constants.baseURL) }

        // Ask for notification permission and register for APNs immediately
        // so silent pushes start arriving as soon as iOS is willing.
        Task { @MainActor in
            await PushService.shared.requestPermissionAndRegister()

            // Location: ask for Always so SLC keeps working in the background.
            // iOS shows "While Using" first; LocationService re-asks for
            // Always once that's granted (see locationManagerDidChangeAuthorization).
            LocationService.shared.requestAlwaysPermission()
            // Safe to call — iOS no-ops if permission isn't granted yet, and
            // the delegate re-calls this once Always is approved.
            LocationService.shared.startSignificantChangeMonitoring()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            await PushService.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("[AppDelegate] failed to register for remote notifications: \(error)")
        #endif
    }

    /// Silent-push entrypoint. iOS gives us ~30 seconds in the background to
    /// fetch location, hit the backend, return.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let result = await PushService.shared.handleSilentPush(userInfo: userInfo)
            completionHandler(result)
        }
    }

    /// Every time the app foregrounds — runs the foreground backfill so any
    /// transactions stuck in 'awaiting' (because LPM, force-quit, or APNs
    /// throttling killed the silent push) get caught up.
    func applicationDidBecomeActive(_ application: UIApplication) {
        // Foregrounding after backgrounding — same hygiene as cold launch.
        // Pre-warm the HTTPClient connection (helps if TCP was dropped while
        // backgrounded) and run the location backfill for awaiting txns.
        Task { await HTTPClient.shared.warmup(baseURL: Constants.baseURL) }
        Task {
            await BackfillService.shared.backfillFromForeground()
        }
    }
}
