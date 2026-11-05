import Foundation

/// A video meeting link found in an event.
public struct MeetingLink: Equatable, Sendable {
    public let url: URL
    /// Display name of the service, e.g. "腾讯会议".
    public let service: String
}

/// Finds video meeting links in event fields (URL, location, notes).
public enum MeetingLinkDetector {
    /// Host suffix → service name.
    static let services: [(host: String, name: String)] = [
        ("meeting.tencent.com", "腾讯会议"),
        ("voovmeeting.com", "腾讯会议"),
        ("vc.feishu.cn", "飞书会议"),
        ("vc.larksuite.com", "飞书会议"),
        ("meeting.dingtalk.com", "钉钉会议"),
        ("zoom.us", "Zoom"),
        ("zoom.com.cn", "Zoom"),
        ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"),
        ("meet.google.com", "Google Meet"),
        ("webex.com", "Webex"),
    ]

    public static func link(in texts: [String?]) -> MeetingLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if let service = services.first(where: { host == $0.host || host.hasSuffix("." + $0.host) }) {
                    return MeetingLink(url: url, service: service.name)
                }
            }
        }
        return nil
    }
}

/// A calendar event or a reminder, independent of EventKit.
public struct CalendarEvent: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case event, reminder }

    public let id: String
    public let kind: Kind
    public let title: String
    /// For a reminder: its due time.
    public let start: Date
    /// For a reminder: the same as `start`.
    public let end: Date
    /// False for reminders due on a day without a time.
    public let hasTime: Bool
    public let location: String
    /// A reminder's notes, on one line.
    public let notes: String
    public let meeting: MeetingLink?

    public init(id: String, kind: Kind = .event, title: String, start: Date, end: Date, hasTime: Bool = true,
                location: String = "", notes: String = "", meeting: MeetingLink? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.start = start
        self.end = end
        self.hasTime = hasTime
        self.location = location
        self.notes = notes
        self.meeting = meeting
    }

    /// Shown in the menu bar from 10 minutes before the start until 5 minutes after it
    /// (30 minutes for reminders, which have no end).
    public func isImminent(now: Date = Date()) -> Bool {
        guard hasTime else { return false }
        let lead: TimeInterval = 10 * 60
        switch kind {
        case .event:
            return now >= start.addingTimeInterval(-lead) && now <= min(start.addingTimeInterval(5 * 60), end)
        case .reminder:
            return now >= start.addingTimeInterval(-lead) && now <= start.addingTimeInterval(30 * 60)
        }
    }

    /// A reminder whose time has passed.
    public func isOverdue(now: Date = Date()) -> Bool {
        kind == .reminder && hasTime && now > start
    }

    public func isOngoing(now: Date = Date()) -> Bool {
        now >= start && now < end
    }
}

extension Array where Element == CalendarEvent {
    /// What to show today, earliest first: events that are ongoing or still to come, and
    /// today's open reminders (including overdue ones, which stay until completed).
    public func upcoming(now: Date = Date(), calendar: Calendar = .current, limit: Int = 3) -> [CalendarEvent] {
        filter { item in
            switch item.kind {
            case .event: return item.end > now && calendar.isDate(item.start, inSameDayAs: now) || item.isOngoing(now: now)
            case .reminder: return calendar.isDate(item.start, inSameDayAs: now)
            }
        }
        .sorted { $0.start < $1.start }
        .prefix(limit)
        .map { $0 }
    }
}
