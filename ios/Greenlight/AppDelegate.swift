import UIKit
import UserNotifications
import WidgetKit
import GreenlightKit

/// Push registration, the notification Allow / Deny actions, and widget refresh on silent pushes.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    enum Action {
        static let allow = "ALLOW"
        static let deny = "DENY"
        static let review = "REVIEW"
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let deny = UNNotificationAction(identifier: Action.deny, title: "Deny", options: [.destructive, .authenticationRequired])
        let allow = UNNotificationAction(identifier: Action.allow, title: "Allow", options: [.authenticationRequired])
        let review = UNNotificationAction(identifier: Action.review, title: "Review", options: [.foreground, .authenticationRequired])
        // The relay picks the category from the risk: high-risk asks get no Allow button.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "GREENLIGHT_ASK", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "GREENLIGHT_ASK_HIGH", actions: [review, deny], intentIdentifiers: []),
        ])
        if SharedStore().config != nil { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await AppModel.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator or no push entitlement: the widget falls back to its timeline refresh.
    }

    /// Silent push from the relay: fetch the latest state and redraw the widgets.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        let store = SharedStore()
        guard let client = store.client, let snapshot = try? await client.snapshot() else { return .failed }
        store.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        return .newData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let askId = response.notification.request.content.userInfo["askId"] as? String else { return }
        switch response.actionIdentifier {
        case Action.allow:
            // Same guard as the widget: from a notification, approve only low or medium risk.
            try? await IntentActions.answer(askId: askId, option: "allow", maxRisk: .medium, source: "iPhone notification")
        case Action.deny:
            try? await IntentActions.answer(askId: askId, option: "deny", maxRisk: .low, source: "iPhone notification")
        default:
            await MainActor.run { AppModel.shared.reviewing = AppModel.Review(id: askId) }
        }
    }
}
