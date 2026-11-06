import GleanerCore
import UserNotifications

/// Posts the twice-daily briefing as a system notification.
@MainActor
enum BriefingNotifier {
    private static let lastSentKey = "lastBriefing"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static let identifierPrefix = "briefing-"

    /// Sends the briefing if one is due and there is something to say: the overview of what is
    /// open, from `compose`, or `fallback` (counts) when that can't be written.
    static func sendIfDue(fallback: String?, defaults: UserDefaults = .standard,
                          compose: @escaping @MainActor () async -> String?) {
        let lastSent = defaults.object(forKey: lastSentKey) as? Date
        guard Briefing.dueSlot(lastSent: lastSent) != nil else { return }
        defaults.set(Date(), forKey: lastSentKey)
        Task { @MainActor in
            guard let message = await compose() ?? fallback else { return }
            let content = UNMutableNotificationContent()
            content.title = "拾穗"
            content.body = message
            let request = UNNotificationRequest(identifier: identifierPrefix + "\(Int(Date().timeIntervalSince1970))",
                                                content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
