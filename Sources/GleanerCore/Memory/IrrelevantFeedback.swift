import Foundation

/// An item the user marked "不相关" once. Recent ones are shown to the model as counter-examples;
/// once several come from the same app, they are offered as a rule that code enforces instead.
public struct IrrelevantExample: Codable, Hashable, Sendable {
    public var summary: String
    public var appID: String
    /// The chat or sender, empty when unknown.
    public var conversation: String
    /// The original message.
    public var excerpt: String
    public var date: Date
    /// Already offered as a rule, so it does not trigger another suggestion.
    public var suggested: Bool

    public init(summary: String, appID: String, conversation: String, excerpt: String, date: Date = Date(),
                suggested: Bool = false) {
        self.summary = summary
        self.appID = appID
        self.conversation = conversation
        self.excerpt = excerpt
        self.date = date
        self.suggested = suggested
    }

    /// "领取美团优惠券（美团）"
    public var promptLine: String {
        conversation.isEmpty ? summary : "\(summary)（\(conversation)）"
    }

    /// The example as a notification, for checking it against a rule.
    public var notification: AppNotification {
        AppNotification(id: "example", appID: appID, title: conversation, body: excerpt.isEmpty ? summary : excerpt,
                        date: date)
    }

    /// Reads both this type and the plain strings saved by earlier versions.
    public static func decodeList<Key: CodingKey>(from container: KeyedDecodingContainer<Key>,
                                                  forKey key: Key) -> [IrrelevantExample] {
        if let list = try? container.decodeIfPresent([IrrelevantExample].self, forKey: key) { return list }
        let legacy = (try? container.decodeIfPresent([String].self, forKey: key)) ?? []
        return legacy.map {
            IrrelevantExample(summary: $0, appID: "", conversation: "", excerpt: "", date: .distantPast, suggested: true)
        }
    }
}

extension Array where Element == IrrelevantExample {
    /// The examples worth turning into a rule: those not yet offered from the app of the latest one,
    /// once there are at least `threshold` of them.
    public func ruleCandidates(threshold: Int = 3) -> [IrrelevantExample]? {
        guard let latest = last(where: { !$0.suggested && !$0.appID.isEmpty }) else { return nil }
        let group = filter { !$0.suggested && $0.appID == latest.appID }
        return group.count >= threshold ? group : nil
    }
}

/// Asks the model for one ignore rule that covers several items the user marked irrelevant.
public struct RuleSuggester: Sendable {
    public var provider: LLMProvider
    public var appName: @Sendable (String) -> String

    public init(provider: LLMProvider, appName: @escaping @Sendable (String) -> String) {
        self.provider = provider
        self.appName = appName
    }

    /// Returns nil when the model's rule is too broad or does not cover the examples.
    public func suggest(from examples: [IrrelevantExample]) async throws -> UserRule? {
        guard !examples.isEmpty else { return nil }
        let output = try await provider.complete(request(for: examples))
        return Self.rule(from: output, covering: examples, appName: appName)
    }

    func request(for examples: [IrrelevantExample]) -> CompletionRequest {
        let lines = examples.map { example in
            let message = example.excerpt.isEmpty ? example.summary : example.excerpt
            return "- 应用：\(appName(example.appID))；会话：\(example.conversation.isEmpty ? "无" : example.conversation)；内容：\(message)"
        }.joined(separator: "\n")
        return CompletionRequest(system: Self.system, user: lines, jsonSchema: Self.schema)
    }

    static func rule(from output: String, covering examples: [IrrelevantExample],
                     appName: (String) -> String) -> UserRule? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        struct Draft: Decodable {
            let text: String
            let app: String?
            let conversation: String?
            let keyword: String?
        }
        guard let draft = try? JSONDecoder().decode(Draft.self, from: Data(output[start...end].utf8)) else { return nil }
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = UserRule(text: text, action: .ignore, app: clean(draft.app),
                            conversation: clean(draft.conversation), keyword: clean(draft.keyword))
        // A rule that ignores everything, or that misses what it was drawn from, is not offered.
        guard !text.isEmpty, rule.app != nil || rule.conversation != nil || rule.keyword != nil else { return nil }
        let covered = examples.filter { rule.matches($0.notification, appName: appName($0.appID)) }
        return covered.count == examples.count ? rule : nil
    }

    static let system = """
    用户把下面这些通知标记为不相关。归纳出一条忽略规则，让以后同类通知不再提醒，但不要误伤其他通知。
    字段：
    - text：规则的一句话描述，不超过 16 字，如"美团的优惠券消息都忽略"
    - app：应用名，照抄给出的应用名
    - conversation：群名或联系人名，只有这些通知都来自同一个会话时才填，否则为空字符串
    - keyword：这些通知内容里都出现的词，能区分同类通知时才填，否则为空字符串
    规则必须覆盖给出的全部通知。只输出 JSON，例如 {"text":"美团的优惠券消息都忽略","app":"美团","conversation":"","keyword":"优惠券"}
    """

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["text","app","conversation","keyword"],
     "properties":{"text":{"type":"string"},"app":{"type":"string"},"conversation":{"type":"string"},
      "keyword":{"type":"string"}}}
    """
}
