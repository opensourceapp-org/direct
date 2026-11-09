import DirectCore
import UIKit
import UserNotifications

/// Local notifications for inbound messages. The payload never leaves this phone.
enum MessageAlerts {
    static let peerKey = "peer"
    static var uiVisible = true

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func show(_ alert: InboundAlert) {
        guard !uiVisible else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.threadId
        content.userInfo = [peerKey: alert.threadId]
        let request = UNNotificationRequest(identifier: alert.threadId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func cancel(threadId: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [threadId])
        center.removePendingNotificationRequests(withIdentifiers: [threadId])
    }

    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }
}
