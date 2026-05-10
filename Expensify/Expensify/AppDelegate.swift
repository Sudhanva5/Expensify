import UIKit

/// Bridge between SwiftUI's @main App struct and UIKit's UIApplicationDelegate.
/// We need this to receive APNs token + silent-push callbacks; SwiftUI's
/// scene lifecycle alone doesn't give those.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Ask for notification permission and register for APNs as soon as the
        // app boots. The first call shows the system prompt; subsequent calls
        // are no-ops.
        Task { @MainActor in
            await PushService.shared.requestPermissionAndRegister()
            // Also nudge the location prompt — second OS dialog the user sees.
            LocationService.shared.requestPermission()
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

    /// Silent-push entrypoint. iOS gives us ~30 seconds of background time
    /// to do everything: fetch location, hit the backend, return.
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
}
