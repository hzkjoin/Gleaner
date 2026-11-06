import Foundation

/// A look over everything still open: what to do first, what takes a quick reply, what can wait.
public struct Overview: Codable, Equatable, Sendable {
    /// One thing to do, pointing at the items it comes from.
    public struct Line: Codable, Equatable, Sendable {
        public var text: String
        public var itemIDs: [UUID]

        public init(text: String, itemIDs: [UUID]) {
            self.text = text
            self.itemIDs = itemIDs
        }
    }

    /// One sentence: how much there is and what matters most.
    public var headline: String
    public var first: [Line]
    public var quick: [Line]
    /// Notices and reminders, in a sentence or two.
    public var later: String
    /// What to do in which order.
    public var advice: String
    /// The items it was written from.
    public var itemIDs: Set<UUID>
    /// What those items said when it was written, to tell when it is out of date.
    public var signature: String = ""
    public var createdAt: Date

    public init(headline: String, first: [Line] = [], quick: [Line] = [], later: String = "", advice: String = "",
                itemIDs: Set<UUID>, createdAt: Date = Date()) {
        self.headline = headline
        self.first = first
        self.quick = quick
        self.later = later
        self.advice = advice
        self.itemIDs = itemIDs
        self.createdAt = createdAt
    }

    /// For a notification: the headline and the advice.
    public var briefing: String {
        [headline, advice].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Changes when items are added or done, and when new messages join an item or its wording,
    /// kind or priority changes.
    public static func signature(of items: [ActionItem]) -> String {
        Overview.items(from: items).map { item in
            "\(item.id)|\(item.notificationDate.timeIntervalSinceReferenceDate)|\(item.kind.rawValue)|\(item.priority.rawValue)|\(item.summary)"
        }.sorted().joined(separator: "\n")
    }

    /// The items an overview covers: everything open except verification codes, which are
    /// over in a minute.
    public static func items(from items: [ActionItem]) -> [ActionItem] {
        items.filter { $0.kind != .code }
    }
}

extension Assistant {
    /// An overview of `items`, by the model; without items, a plain line and no call.
    public func overview(of items: [ActionItem], now: Date = Date(),
                         appName: @escaping @Sendable (String) -> String = { $0 }) async throws -> Overview {
        let items = Overview.items(from: items)
        guard !items.isEmpty else {
            var empty = Overview(headline: "暂时没有要处理的事", itemIDs: [])
            empty.signature = Overview.signature(of: [])
            return empty
        }
        let output = try await provider.complete(overviewRequest(items: items, now: now, appName: appName))
        guard let overview = Self.parseOverview(output, items: items, now: now) else {
            throw LLMError.unexpectedResponse(String(output.prefix(300)))
        }
        return overview
    }

    func overviewRequest(items: [ActionItem], now: Date, appName: (String) -> String) -> CompletionRequest {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE HH:mm"
        let time = DateFormatter()
        time.dateFormat = "MM-dd HH:mm"
        let system = """
        你在帮用户快速了解手上还没处理的事，让他不用一条条去看。用户的称呼：\(names)。现在是 \(formatter.string(from: now))。
        下面每个事项有编号、类型、优先级、截止时间、来源、摘要和原始消息。只输出 JSON：
        - headline：一句话结论，例如"现在有 3 件事要你处理，最急的是周凯要方案意见"；都不急就说"暂时没有急事"之类，不超过 40 字
        - first：需要先处理的（有截止时间、优先级高、有人在等结果的），每件一条：text 写"谁 + 什么事（时限）"，不超过 24 字；items 列出对应的编号，同一件事的多个编号放在一起
        - quick：回一句话就能结束的，格式同上
        - later：值得关注、提醒这类不急的，合成一两句话带过，说个数和大意，不超过 60 字；没有就写空字符串
        - advice：根据轻重缓急，给一句先做什么、后做什么的建议，不超过 40 字，用"可以""建议"的口吻
        - 每个编号最多出现在一个地方；不要编出列表里没有的事；用"你"称呼用户；不要使用"·"符号

        \(RecordNote.text)

        例如：{"headline":"……","first":[{"items":[1,4],"text":"……"}],"quick":[{"items":[2],"text":"……"}],"later":"……","advice":"……"}
        """
        let user = items.enumerated().map { index, item in
            var line = "[\(index + 1)] \(Self.kindLabel(item.kind))，优先级\(Self.priorityLabel(item.priority))"
            if !item.due.isEmpty { line += "，截止：\(item.due)" }
            let source = [appName(item.appID), item.sourceTitle].filter { !$0.isEmpty }.joined(separator: "，")
            line += "\n来源：\(source)，\(time.string(from: item.notificationDate))\n摘要：\(item.summary)"
            let messages = zip(item.messages, item.messageDates).suffix(3).map { message, date in
                (date.map { time.string(from: $0) + " " } ?? "") + message.replacingOccurrences(of: "\n", with: " ")
            }
            if !messages.isEmpty { line += "\n原始消息：\n" + messages.joined(separator: "\n") }
            return line
        }.joined(separator: "\n\n")
        return CompletionRequest(system: system, user: user, jsonSchema: Self.overviewSchema)
    }

    static func kindLabel(_ kind: ActionKind) -> String {
        switch kind {
        case .reply: return "需要回复"
        case .task: return "待办"
        case .code: return "验证码"
        case .alert: return "提醒"
        case .notice: return "值得关注"
        }
    }

    static func priorityLabel(_ priority: Priority) -> String {
        switch priority {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    static func parseOverview(_ output: String, items: [ActionItem], now: Date) -> Overview? {
        var text = output
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let headline = (json["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty
        else { return nil }
        var used = Set<Int>()
        func lines(_ key: String) -> [Overview.Line] {
            ((json[key] as? [[String: Any]]) ?? []).compactMap { entry in
                let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let numbers = ((entry["items"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
                    .filter { items.indices.contains($0 - 1) && used.insert($0).inserted }
                guard !text.isEmpty, !numbers.isEmpty else { return nil }
                return Overview.Line(text: text, itemIDs: numbers.map { items[$0 - 1].id })
            }
        }
        func string(_ key: String) -> String { (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var overview = Overview(headline: headline, first: lines("first"), quick: lines("quick"), later: string("later"),
                                advice: string("advice"), itemIDs: Set(items.map(\.id)), createdAt: now)
        overview.signature = Overview.signature(of: items)
        return overview
    }

    static let overviewSchema = """
    {"type":"object","additionalProperties":false,"required":["headline","first","quick","later","advice"],
     "properties":{"headline":{"type":"string"},
      "first":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["items","text"],
        "properties":{"items":{"type":"array","items":{"type":"integer"}},"text":{"type":"string"}}}},
      "quick":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["items","text"],
        "properties":{"items":{"type":"array","items":{"type":"integer"}},"text":{"type":"string"}}}},
      "later":{"type":"string"},"advice":{"type":"string"}}}
    """
}
