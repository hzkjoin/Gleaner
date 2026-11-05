import Foundation

/// What happened to one notification: kept as an item or news, or skipped and why.
public struct ActivityRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Outcome: Codable, Hashable, Sendable {
        case item(kind: ActionKind, summary: String)
        case news(headline: String)
        case skipped(SkipReason)
    }

    public enum SkipReason: String, Codable, Sendable {
        /// The model found nothing to act on.
        case notActionable
        /// A group message that @mentions only other people.
        case mentionsOthers
        case mutedConversation
        case ignoredApp
        case empty
        /// The same message, already handled through another source.
        case duplicate
        /// A user rule said to ignore it.
        case rule
    }

    /// The notification's id.
    public var id: String
    public var appID: String
    public var origin: DeviceOrigin
    public var title: String
    public var excerpt: String
    public var date: Date
    public var outcome: Outcome

    public init(notification: AppNotification, outcome: Outcome) {
        id = notification.id
        appID = notification.appID
        origin = notification.origin
        title = notification.title
        excerpt = String(notification.body.replacingOccurrences(of: "\n", with: " ").prefix(120))
        date = notification.date
        self.outcome = outcome
    }

    public var isKept: Bool {
        if case .skipped = outcome { return false }
        return true
    }
}

extension Array where Element == ActivityRecord {
    /// Adds `new` records, newest first, dropping repeats, anything older than `maxAge`,
    /// and anything beyond `limit`.
    public func merging(_ new: [ActivityRecord], now: Date = Date(), maxAge: TimeInterval = 86_400,
                        limit: Int = 500) -> [ActivityRecord] {
        var seen = Set<String>()
        return (new + self)
            .filter { seen.insert($0.id).inserted && now.timeIntervalSince($0.date) <= maxAge }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }
}
