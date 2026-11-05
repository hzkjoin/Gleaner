import Foundation

/// How long items stay in the list, and when snoozed items come back.
public enum ItemLifecycle {
    /// Verification codes are useless after a few minutes.
    public static let codeLifetime: TimeInterval = 10 * 60
    /// Anything else is archived after a day without action.
    public static let itemLifetime: TimeInterval = 24 * 60 * 60
    /// A code counts as "just arrived" (worth flashing in the menu bar and copying) for this long.
    public static let freshCodeWindow: TimeInterval = 2 * 60

    /// When an item starts aging: when it was found, or when its snooze ended.
    static func ageStart(of item: ActionItem) -> Date {
        max(item.createdAt, item.snoozedUntil ?? item.createdAt)
    }

    public static func isExpired(_ item: ActionItem, now: Date = Date()) -> Bool {
        if item.kind == .code {
            return now.timeIntervalSince(item.notificationDate) > codeLifetime
        }
        return now.timeIntervalSince(ageStart(of: item)) > itemLifetime
    }

    /// Hidden while snoozed.
    public static func isVisible(_ item: ActionItem, now: Date = Date()) -> Bool {
        guard let until = item.snoozedUntil else { return true }
        return now >= until
    }

    public static func isFreshCode(_ item: ActionItem, now: Date = Date()) -> Bool {
        item.kind == .code && now.timeIntervalSince(item.notificationDate) <= freshCodeWindow
    }
}

/// Choices offered by "稍后提醒".
public enum SnoozeOption: String, CaseIterable, Identifiable, Sendable {
    case oneHour, tonight, tomorrowMorning

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oneHour: return "1 小时后"
        case .tonight: return "今晚 20:00"
        case .tomorrowMorning: return "明早 9:00"
        }
    }

    /// When the item should come back, or nil if the option makes no sense right now
    /// (e.g. "tonight" after 19:00).
    public func date(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .tonight:
            guard let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now),
                  tonight.timeIntervalSince(now) >= 3600 else { return nil }
            return tonight
        case .tomorrowMorning:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
    }
}

/// An item that left the list, kept so it can be found and restored.
public struct ResolvedItem: Codable, Identifiable, Hashable, Sendable {
    public enum Resolution: String, Codable, Sendable {
        case done
        /// Archived automatically after its lifetime.
        case archived
        /// Marked "不相关" by the user.
        case irrelevant
        /// Added to Reminders or Calendar, which takes over from here.
        case scheduled
    }

    public var item: ActionItem
    public var resolution: Resolution
    public var date: Date
    public var id: UUID { item.id }

    public init(item: ActionItem, resolution: Resolution, date: Date = Date()) {
        self.item = item
        self.resolution = resolution
        self.date = date
    }
}
