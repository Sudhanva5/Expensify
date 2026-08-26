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

        // Move any pre-App-Group spend-time buffer into the shared container
        // before anything reads it. No-op after the first launch that runs
        // it, and the app is the only migrator — the location-push extension
        // must never race this.
        SharedLocationStore.migrateFromStandardIfNeeded()

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
            // Same deal for location pushes: needs authorization to exist
            // before iOS mints a token, and the authorization delegate
            // re-runs it after an upgrade. Calling here covers the launch
            // where permission was already granted in a previous session.
            LocationService.shared.startLocationPushMonitoring()
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

    /// Everything that should happen when the app becomes active.
    ///
    /// NOT called from `applicationDidBecomeActive(_:)` any more. This app is
    /// scene-based (SwiftUI `App` + a generated `UIApplicationSceneManifest`),
    /// and UIKit does not deliver the non-scene lifecycle callbacks to the app
    /// delegate in that configuration — so that method had never run, and the
    /// foreground catchup it was supposed to drive had never happened. The
    /// evidence: on a day with rows sitting `awaiting`, every single
    /// `GET /transactions/awaiting` in the server logs came from the SLC path
    /// on its 5-minute cadence, and opening the app produced none at all.
    ///
    /// `ExpensifyApp` now drives this from `scenePhase`, which does fire.
    static func handleBecameActive() {
        // Foregrounding after backgrounding — same hygiene as cold launch.
        // Pre-warm the HTTPClient connection (helps if TCP was dropped while
        // backgrounded) and run the location backfill for awaiting txns.
        Task { await HTTPClient.shared.warmup(baseURL: Constants.baseURL) }
        Task {
            // Warm the spend-time buffer BEFORE the backfill reads it. The
            // user frequently opens the app within a minute or two of paying,
            // and that fix is a legitimate sample for the transaction that
            // just landed — but only if it's in the buffer before
            // backfillAwaiting() does its lookup. Debounced internally,
            // so a foreground/background flap costs nothing.
            await LocationService.shared.captureIntoBufferIfNeeded()
            await BackfillService.shared.backfillAwaiting(trigger: .foreground)
        }
    }
}
