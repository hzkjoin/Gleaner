import Foundation

/// A rule the user wrote in plain words, compiled once by the model into conditions that
/// code then enforces exactly.
public struct UserRule: Codable, Identifiable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Never analyze or show.
        case ignore
        /// Mark resulting items as high priority.
        case urgent
        /// Keep resulting items as low-priority notices.
        case notice
    }

    public var id: UUID
    /// What the user wrote, e.g. "王总的消息都标紧急".
    public var text: String
    public var action: Action
    /// App name or bundle id fragment, e.g. "微信".
    public var app: String?
    /// Chat or sender name fragment, e.g. "王总".
    public var conversation: String?
    /// Text that must appear in the message.
    public var keyword: String?
    /// 1 = Monday … 7 = Sunday.
    public var weekdays: [Int]?
    /// Start and end hour, end exclusive; may wrap midnight (e.g. [22, 8]).
    public var hours: [Int]?

    public init(id: UUID = UUID(), text: String, action: Action, app: String? = nil, conversation: String? = nil,
                keyword: String? = nil, weekdays: [Int]? = nil, hours: [Int]? = nil) {
        self.id = id
        self.text = text
        self.action = action
        self.app = app
        self.conversation = conversation
        self.keyword = keyword
        self.weekdays = weekdays
        self.hours = hours
    }

    public func matches(_ note: AppNotification, appName: String, calendar: Calendar = .current) -> Bool {
        func contains(_ text: String, _ fragment: String?) -> Bool {
            guard let fragment = fragment?.trimmingCharacters(in: .whitespaces), !fragment.isEmpty else { return true }
            return text.localizedCaseInsensitiveContains(fragment)
        }
        guard contains(appName, app) || contains(note.appID, app),
              contains(note.title, conversation),
              contains(note.title + " " + note.body, keyword) else { return false }

        if let weekdays, !weekdays.isEmpty {
            // Calendar weekday: 1 = Sunday … 7 = Saturday → 1 = Monday … 7 = Sunday.
            let weekday = (calendar.component(.weekday, from: note.date) + 5) % 7 + 1
            guard weekdays.contains(weekday) else { return false }
        }
        if let hours, hours.count == 2 {
            let hour = calendar.component(.hour, from: note.date)
            let (start, end) = (hours[0], hours[1])
            let inside = start <= end ? (hour >= start && hour < end) : (hour >= start || hour < end)
            guard inside else { return false }
        }
        return true
    }

    /// "微信，王总：紧急"
    public var summary: String {
        var parts: [String] = []
        if let app, !app.isEmpty { parts.append(app) }
        if let conversation, !conversation.isEmpty { parts.append(conversation) }
        if let keyword, !keyword.isEmpty { parts.append("含「\(keyword)」") }
        if let weekdays, !weekdays.isEmpty {
            parts.append(weekdays == [6, 7] ? "周末" : weekdays == [1, 2, 3, 4, 5] ? "工作日" : "周" + weekdays.map(String.init).joined(separator: "、"))
        }
        if let hours, hours.count == 2 { parts.append("\(hours[0]):00–\(hours[1]):00") }
        let target = parts.isEmpty ? "全部" : parts.joined(separator: "，")
        let verb: String
        switch action {
        case .ignore: verb = "忽略"
        case .urgent: verb = "紧急"
        case .notice: verb = "仅关注"
        }
        return "\(target)：\(verb)"
    }
}

/// Compiles a plain-words rule with the model.
public struct RuleCompiler: Sendable {
    public var provider: LLMProvider

    public init(provider: LLMProvider) {
        self.provider = provider
    }

    public func compile(_ text: String) async throws -> UserRule {
        let request = CompletionRequest(system: Self.system, user: text, jsonSchema: Self.schema)
        let output = try await provider.complete(request)
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else {
            throw LLMError.unexpectedResponse(String(output.prefix(200)))
        }
        struct Draft: Decodable {
            let action: String
            let app: String?
            let conversation: String?
            let keyword: String?
            let weekdays: [Int]?
            let hours: [Int]?
        }
        let draft = try JSONDecoder().decode(Draft.self, from: Data(output[start...end].utf8))
        guard let action = UserRule.Action(rawValue: draft.action) else {
            throw LLMError.unexpectedResponse(draft.action)
        }
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return UserRule(text: text, action: action, app: clean(draft.app), conversation: clean(draft.conversation),
                        keyword: clean(draft.keyword),
                        weekdays: draft.weekdays.flatMap { $0.isEmpty ? nil : $0.filter { (1...7).contains($0) } },
                        hours: draft.hours.flatMap { $0.count == 2 ? $0 : nil })
    }

    static let system = """
    把用户写的一条通知规则转换成 JSON。字段：
    - action：ignore（不提醒、忽略）、urgent（标为紧急）、notice（只作为关注，不当待办）
    - app：应用名，如"微信""企业微信""美团"，没有则为空字符串
    - conversation：群名或联系人名，没有则为空字符串
    - keyword：消息里必须出现的词，没有则为空字符串
    - weekdays：星期几生效，1 是周一，7 是周日，周末是 [6,7]，不限则为 []
    - hours：生效时段 [开始小时, 结束小时]，如晚上十点到早上八点为 [22,8]，不限则为 []
    只输出 JSON，例如 {"action":"urgent","app":"","conversation":"王总","keyword":"","weekdays":[],"hours":[]}
    """

    static let schema = """
    {"type":"object","additionalProperties":false,
     "required":["action","app","conversation","keyword","weekdays","hours"],
     "properties":{"action":{"type":"string","enum":["ignore","urgent","notice"]},
      "app":{"type":"string"},"conversation":{"type":"string"},"keyword":{"type":"string"},
      "weekdays":{"type":"array","items":{"type":"integer"}},"hours":{"type":"array","items":{"type":"integer"}}}}
    """
}
