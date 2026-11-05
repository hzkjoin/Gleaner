import Foundation

/// A chat or sender within an app, identified the way notifications show it:
/// the app plus the notification title (group name or contact name).
public struct ConversationKey: Codable, Hashable, Sendable {
    public var appID: String
    public var title: String

    public init(appID: String, title: String) {
        self.appID = appID
        self.title = title
    }
}

/// User-defined rules applied before anything reaches the model. Rules are exact and
/// enforced in code, so a muted group stays muted regardless of what the model thinks.
public struct NotificationFilter: Sendable {
    public var ignoredApps: Set<String>
    public var mutedConversations: Set<ConversationKey>
    public var rules: [UserRule]
    /// Display name for an app id, for rules written with app names.
    public var appName: @Sendable (String) -> String

    public init(ignoredApps: Set<String> = [], mutedConversations: Set<ConversationKey> = [],
                rules: [UserRule] = [], appName: @escaping @Sendable (String) -> String = { $0 }) {
        self.ignoredApps = ignoredApps
        self.mutedConversations = mutedConversations
        self.rules = rules
        self.appName = appName
    }

    /// Why `notification` is filtered out, or nil when it is allowed.
    public func skipReason(for notification: AppNotification) -> ActivityRecord.SkipReason? {
        if ignoredApps.contains(notification.appID) { return .ignoredApp }
        if mutedConversations.contains(ConversationKey(appID: notification.appID, title: notification.title)) {
            return .mutedConversation
        }
        if action(for: notification) == .ignore { return .rule }
        return nil
    }

    public func allows(_ notification: AppNotification) -> Bool {
        skipReason(for: notification) == nil
    }

    /// The first rule matching `notification`, if any.
    public func action(for notification: AppNotification) -> UserRule.Action? {
        guard !rules.isEmpty else { return nil }
        let name = appName(notification.appID)
        return rules.first { $0.matches(notification, appName: name) }?.action
    }

    public func allows(_ item: ActionItem) -> Bool {
        !ignoredApps.contains(item.appID)
            && !mutedConversations.contains(ConversationKey(appID: item.appID, title: item.sourceTitle))
    }
}
