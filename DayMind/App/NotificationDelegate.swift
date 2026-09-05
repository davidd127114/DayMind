import Foundation
import UserNotifications
import UIKit

/// Handles notification presentation and the Complete / Snooze / Open actions. Works with no AI.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let reminderID = (userInfo[NotificationCategory.reminderIDKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            let env = AppEnvironment.shared
            Task { @MainActor in
                if let reminderID, let reminder = env.reminders.fetch(id: reminderID) {
                    switch action {
                    case NotificationCategory.actionComplete:
                        _ = try? await env.reminders.complete(reminder)
                    case NotificationCategory.actionSnoozeHour:
                        _ = try? await env.reminders.snooze(reminder, by: 3600)
                    default:
                        env.router.open(reminderID: reminderID)
                    }
                } else if response.notification.request.identifier == NotificationCategory.briefingIdentifier {
                    env.router.openBook(.upcoming)
                }
            }
        }
    }
}

/// Registers the notification delegate before any notification can arrive.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }
}
