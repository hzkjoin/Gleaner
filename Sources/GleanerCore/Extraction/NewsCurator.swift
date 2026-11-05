import Foundation

/// Picks news, trending topics and market updates out of notifications, for browsing.
///
/// Separate from `ActionExtractor` on purpose: action extraction tells the model to ignore
/// news, and a small model does each job better with its own focused prompt. Writing a
/// headline needs no reasoning, so this call can run with reasoning off.
public struct NewsCurator: Sendable {
    public var provider: LLMProvider
    public var appName: @Sendable (String) -> String

    /// Apps whose notifications are personal messages, never news.
    static let messagingApps: Set<String> = MentionAnalyzer.groupChatApps.union([
        "com.apple.MobileSMS", "com.apple.mobilesms", "com.apple.iChat",
    ])

    public init(provider: LLMProvider, appName: @escaping @Sendable (String) -> String = { $0 }) {
        self.provider = provider
        self.appName = appName
    }

    /// News items found in `notifications`; empty when there are none.
    public func curate(_ notifications: [AppNotification]) async throws -> [NewsItem] {
        let candidates = notifications.filter {
            $0.hasContent && !Self.messagingApps.contains($0.appID) && VerificationCodeDetector.item(for: $0) == nil
        }
        guard !candidates.isEmpty else { return [] }

        let request = CompletionRequest(
            system: NewsPrompt.system,
            user: NewsPrompt.user(notifications: candidates, appName: appName),
            jsonSchema: NewsPrompt.schema
        )
        return try Self.parse(try await provider.complete(request)).compactMap { Self.makeItem(from: $0, batch: candidates) }
    }

    struct Entry: Decodable, Equatable {
        let sources: [Int]
        let headline: String
        let category: String?
    }

    static func parse(_ output: String) throws -> [Entry] {
        var text = output
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            if ActionExtractor.isEmptyObject(output) { return [] }
            throw LLMError.unexpectedResponse(String(output.prefix(300)))
        }
        struct Envelope: Decodable { let news: [Entry]? }
        do {
            return try JSONDecoder().decode(Envelope.self, from: Data(text[start...end].utf8)).news ?? []
        } catch {
            throw LLMError.unexpectedResponse(String(output.prefix(300)))
        }
    }

    static func makeItem(from entry: Entry, batch: [AppNotification]) -> NewsItem? {
        let sources = entry.sources.filter { (1...batch.count).contains($0) }.map { batch[$0 - 1] }
        let headline = entry.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latest = sources.max(by: { $0.date < $1.date }), !headline.isEmpty else { return nil }
        var item = NewsItem(
            headline: headline,
            category: NewsCategory(label: entry.category ?? ""),
            appID: latest.appID,
            origin: latest.origin,
            sourceTitle: latest.title,
            sourceExcerpt: sources.map(\.body).joined(separator: " / "),
            date: latest.date
        )
        item.sourceIDs = sources.map(\.id)
        return item
    }
}

enum NewsPrompt {
    static let system = """
    下面是用户收到的一批 App 通知。请从中挑出属于【新闻、热搜、热点事件、行业或市场动态】的内容，
    整理成简洁的资讯条目，方便用户快速浏览。

    要选：
    - 新闻资讯、社会事件、政策发布
    - 社交平台推送的热门话题，包括明星、娱乐、八卦类的热搜事件
    - 股市、行业、公司动态

    不要选：
    - 营销推广、优惠、促销、抵扣、领券、直播带货
    - 点赞、关注、评论、私信等社交互动
    - 个人消息、账单、物流、系统通知、验证码
    - 只有"你关注的人发布了新内容"这类没有具体事件的推送

    规则：
    - headline 用一句话客观概括事件，不超过 30 个字；不要标题党，去掉"点开看>>""速看"这类话术和表情
    - category 取 热搜、财经、科技、社会、娱乐、体育、其他 之一
    - 同一事件的多条通知合并成一条，sources 列出所有相关编号
    - 没有符合的内容时输出 {"news":[]}

    只输出 JSON：{"news":[{"sources":[1],"headline":"...","category":"财经"}]}
    """

    static func user(notifications: [AppNotification], appName: (String) -> String) -> String {
        notifications.enumerated().map { index, note in
            var title = note.title
            if !note.subtitle.isEmpty { title += " / \(note.subtitle)" }
            let body = note.body.replacingOccurrences(of: "\n", with: " ")
            return "[\(index + 1)] \(appName(note.appID)) | \(title) | \(body)"
        }.joined(separator: "\n")
    }

    static let schema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["news"],
      "properties": {
        "news": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["sources", "headline", "category"],
            "properties": {
              "sources": {"type": "array", "items": {"type": "integer"}},
              "headline": {"type": "string"},
              "category": {"type": "string", "enum": ["热搜", "财经", "科技", "社会", "娱乐", "体育", "其他"]}
            }
          }
        }
      }
    }
    """
}
