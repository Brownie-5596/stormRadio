import UserNotifications
import UIKit
import StormRadioCore

/// Posts iOS notifications for announcements (shown on the lock screen and in Notification Center).
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Called on the main thread with an announcement id when the user taps a notification.
    var onOpen: ((String) -> Void)?

    func requestPermission() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    func post(_ a: Announcement) {
        let content = UNMutableNotificationContent()
        content.title = a.title
        content.body = a.spokenText
        content.userInfo = ["announcementID": a.id]
        content.threadIdentifier = a.category.rawValue
        // The radio speaks; the notification itself stays quiet unless it's top priority.
        content.sound = a.priority >= 9 ? .default : nil
        if a.priority >= 8 { content.interruptionLevel = .active }
        let req = UNNotificationRequest(identifier: a.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // Show only in the list while the app is open (the radio is already speaking).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["announcementID"] as? String {
            DispatchQueue.main.async { self.onOpen?(id) }
        }
        completionHandler()
    }
}
