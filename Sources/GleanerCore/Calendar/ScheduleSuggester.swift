import Foundation

/// A proposed calendar event or reminder for an item, waiting for the user's confirmation.
public struct ScheduleSuggestion: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Something to attend, with a start time: goes to Calendar.
        case event
        /// Something to finish by a time: goes to Reminders.
        case reminder
    }

    public var kind: Kind
    public var title: String
    public var start: Date
    /// Events only; nil means an hour after `start`.
    public var end: Date?
    /// Only the day is known.
    public var allDay: Bool
    public var location: String
    public var notes: String

    public init(kind: Kind, title: String, start: Date, end: Date? = nil, allDay: Bool = false,
                location: String = "", notes: String = "") {
        self.kind = kind
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
    }

    /// When an event ends: the given end, or an hour after it starts.
    public var effectiveEnd: Date {
        if let end, end > start { return end }
        return start.addingTimeInterval(3600)
    }
}

/// Decides which items are worth putting in Calendar or Reminders, and extracts what's needed.
///
/// A separate call from item extraction, made only for items that mention a time.
public struct ScheduleSuggester: Sendable {
    public var provider: LLMProvider
    public var appName: @Sendable (String) -> String
    public var timeZone: TimeZone

    public init(provider: LLMProvider, appName: @escaping @Sendable (String) -> String, timeZone: TimeZone = .current) {
        self.provider = provider
        self.appName = appName
        self.timeZone = timeZone
    }

    /// Items worth asking about: not codes or files, and with a due time or a time in the text.
    public static func candidates(_ items: [ActionItem]) -> [ActionItem] {
        items.filter { item in
            guard item.kind != .code, item.attachmentPath == nil, item.schedules.isEmpty else { return false }
            if !item.due.isEmpty { return true }
            return DueDateParser.parse(item.summary + " " + item.sourceExcerpt, now: item.notificationDate) != nil
        }
    }

    /// Several times for one item at most (a course over a few days, not a whole timetable).
    static let perItemLimit = 6

    /// Suggestions by item id, in time order; items not worth scheduling are left out.
    public func suggest(for items: [ActionItem], now: Date = Date()) async throws -> [UUID: [ScheduleSuggestion]] {
        guard !items.isEmpty else { return [:] }
        let output = try await provider.complete(request(for: items, now: now))
        return parse(output, items: items, now: now)
    }

    func request(for items: [ActionItem], now: Date) -> CompletionRequest {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        let time = DateFormatter()
        time.timeZone = timeZone
        time.dateFormat = "MM-dd HH:mm"
        let system = """
        下面是从用户消息里整理出的事项。判断哪些值得加到用户的日历或提醒事项，并提取需要的信息。
        现在是 \(formatter.string(from: now))。

        - 值得添加：有明确日期或时间，用户需要参加，或要在那之前完成的事，如会议、电话、面试、约见、航班、截止日期
        - 不值得：没有具体时间、时间已经过去、只是新闻或别人的安排
        - 同一个事项里有几个时间（如两天各有一节课、几场会议），每个时间各输出一条，index 相同，title 写出区别（如"第三课""第四课"）
        - type：要参加、有开始时间的用 event；要在某个时间之前完成的用 reminder
        - title：不超过 20 字，写清做什么，可以带上对方的称呼
        - start：本地时间，如 2026-11-06T15:00；只知道日期时写 2026-11-06，并把 all_day 设为 true
        - end：event 的结束时间，不知道就写空字符串
        - location：地点或会议链接，没有就写空字符串
        - notes：一句补充，没有就写空字符串
        只输出 JSON，例如 {"suggestions":[{"index":1,"worth":true,"type":"event","title":"项目评审会","start":"2026-11-06T15:00","end":"","all_day":false,"location":"3 楼会议室","notes":""}]}
        """
        let user = items.enumerated().map { index, item in
            var lines = ["\(index + 1). 事项：\(item.summary)"]
            if !item.due.isEmpty { lines.append("   截止：\(item.due)") }
            if !item.sourceExcerpt.isEmpty { lines.append("   原消息：\(item.sourceExcerpt)") }
            let source = [appName(item.appID), item.sourceTitle].filter { !$0.isEmpty }.joined(separator: " ")
            lines.append("   来源：\(source)，收到于 \(time.string(from: item.notificationDate))")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        return CompletionRequest(system: system, user: user, jsonSchema: Self.schema)
    }

    func parse(_ output: String, items: [ActionItem], now: Date) -> [UUID: [ScheduleSuggestion]] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any],
              let suggestions = json["suggestions"] as? [[String: Any]] else { return [:] }
        var result: [UUID: [ScheduleSuggestion]] = [:]
        for entry in suggestions {
            guard entry["worth"] as? Bool == true,
                  let index = entry["index"] as? Int, items.indices.contains(index - 1),
                  let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let (startDate, dateOnly) = date(entry["start"] as? String) else { continue }
            let kind = ScheduleSuggestion.Kind(rawValue: entry["type"] as? String ?? "") ?? .reminder
            let allDay = dateOnly || entry["all_day"] as? Bool == true
            // Past times aren't worth adding; nor are dates far off, which are usually misreadings.
            let reference = allDay ? Calendar.current.startOfDay(for: now) : now.addingTimeInterval(-3600)
            guard startDate >= reference, startDate <= now.addingTimeInterval(400 * 86_400) else { continue }
            var endDate = date(entry["end"] as? String)?.0
            if let value = endDate, value <= startDate { endDate = nil }
            func text(_ key: String) -> String { (entry[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            let suggestion = ScheduleSuggestion(
                kind: kind, title: String(title.prefix(40)), start: startDate, end: kind == .event && !allDay ? endDate : nil,
                allDay: allDay, location: text("location"), notes: text("notes"))
            let id = items[index - 1].id
            // The same time twice is one suggestion.
            guard !(result[id] ?? []).contains(where: { $0.start == suggestion.start && $0.kind == suggestion.kind }),
                  (result[id]?.count ?? 0) < Self.perItemLimit else { continue }
            result[id, default: []].append(suggestion)
        }
        return result.mapValues { $0.sorted { $0.start < $1.start } }
    }

    /// "2026-11-06T15:00" (or with seconds) or "2026-11-06"; the flag is true for a date alone.
    func date(_ text: String?) -> (Date, Bool)? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for (format, dateOnly) in [("yyyy-MM-dd'T'HH:mm:ss", false), ("yyyy-MM-dd'T'HH:mm", false),
                                   ("yyyy-MM-dd HH:mm", false), ("yyyy-MM-dd", true)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return (date, dateOnly) }
        }
        return nil
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["suggestions"],
     "properties":{"suggestions":{"type":"array","items":{"type":"object","additionalProperties":false,
      "required":["index","worth","type","title","start","end","all_day","location","notes"],
      "properties":{"index":{"type":"integer"},"worth":{"type":"boolean"},"type":{"type":"string","enum":["event","reminder"]},
       "title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},"all_day":{"type":"boolean"},
       "location":{"type":"string"},"notes":{"type":"string"}}}}}}
    """
}
