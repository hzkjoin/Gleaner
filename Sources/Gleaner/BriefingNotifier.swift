import GleanerCore
import UserNotifications

/// Posts the twice-daily briefing as a system notification.
@MainActor
enum BriefingNotifier {
    private static let lastSentKey = "lastBriefing"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Sends the briefing if one is due and there is something to say.
    static func sendIfDue(actionable: Int, news: Int, defaults: UserDefaults = .standard) {
        let lastSent = defaults.object(forKey: lastSentKey) as? Date
        guard Briefing.dueSlot(lastSent: lastSent) != nil else { return }
        defaults.set(Date(), forKey: lastSentKey)
        guard let message = Briefing.message(actionable: actionable, news: news) else { return }

        let content = UNMutableNotificationContent()
        content.title = "拾穗"
        content.body = message
        let request = UNNotificationRequest(identifier: "briefing-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
