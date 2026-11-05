import Foundation

/// Drafts replies for items that came from a person.
///
/// Kept separate from extraction on purpose: asking a small model to classify, extract
/// and write in one pass makes it drop the replies. A short, focused prompt does better,
/// and writing one casual sentence needs no reasoning, so this call can run fast.
public struct ReplyWriter: Sendable {
    public var provider: LLMProvider
    /// Recent messages of an item's conversation, oldest first, so the reply fits what was said.
    public var context: @Sendable (ActionItem) -> [ArchivedMessage]

    public init(provider: LLMProvider, context: @escaping @Sendable (ActionItem) -> [ArchivedMessage] = { _ in [] }) {
        self.provider = provider
        self.context = context
    }

    /// Returns `items` with `suggestedReply` filled in where a reply makes sense.
    ///
    /// Replies are a convenience: if the model fails, the items come back unchanged
    /// rather than failing the batch they belong to.
    public func addReplies(to items: [ActionItem], userNames: [String]) async -> [ActionItem] {
        // "某人在群聊中@了你" carries no message, so there is nothing to reply to.
        let candidates = items.indices.filter {
            items[$0].kind.acceptsReply && items[$0].suggestedReply.isEmpty && !Self.onlySaysMentioned(items[$0])
        }
        guard !candidates.isEmpty else { return items }

        let request = CompletionRequest(
            system: ReplyPrompt.system(userNames: userNames),
            user: ReplyPrompt.user(items: candidates.map { items[$0] }, context: context),
            jsonSchema: ReplyPrompt.schema
        )
        guard let output = try? await provider.complete(request), let replies = try? Self.parse(output) else {
            return items
        }

        var result = items
        for reply in replies where (1...candidates.count).contains(reply.id) {
            let text = reply.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result[candidates[reply.id - 1]].suggestedReply = text }
        }
        return result
    }

    /// Every message of the item is WeChat's "某人在群聊中@了你", without the message itself.
    static func onlySaysMentioned(_ item: ActionItem) -> Bool {
        let messages = item.messages
        return !messages.isEmpty && messages.allSatisfy(MentionAnalyzer.saysMentionedYou)
    }

    struct Reply: Decodable, Equatable {
        let id: Int
        let reply: String
    }

    static func parse(_ output: String) throws -> [Reply] {
        var text = output
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw LLMError.unexpectedResponse(String(output.prefix(300)))
        }
        struct Envelope: Decodable { let replies: [Reply] }
        return try JSONDecoder().decode(Envelope.self, from: Data(text[start...end].utf8)).replies
    }
}

enum ReplyPrompt {
    static func system(userNames: [String]) -> String {
        let names = userNames.isEmpty ? "用户" : userNames.joined(separator: "、")
        return """
        你在帮\(names)回消息。下面每一条是别人发给他的消息，附有这个会话最近的聊天记录。
        请结合上下文，以他本人的口吻，各写一句可以直接发出去的回复。
        聊天记录里标"我:"的是他自己说过的话，回复要和他之前的说法、语气保持一致，不要重复已经说过的内容。
        其他都是别人说的；他在微信等应用里发的话不在记录里，不要以为他没回过。
        看不出对方在说什么时，回复问清楚就好，不要编造事实。

        要求：
        - 像在微信里随手回的一句话：口语、简短，一般 5 到 25 个字
        - 不要"您好""收到，确认后回复您""感谢您的消息"这类客服腔和套话
        - 对领导礼貌但自然，对同事、朋友轻松直接
        - 能直接回答就直接回答；对方已经给出的时间、要求，直接确认，不要再用占位符
        - 只有他本人才知道、对方也没说的信息，才用【时间】【数字】这样的占位符
        - 不要说已经做完、已经准备好的事
        - 如果这条消息不是某个人发来的（例如系统通知），reply 为空字符串
        - 如果只知道"某人在群聊中@了你"、不知道对方具体说了什么，reply 为空字符串，不要猜

        示例：
        - 同事问"这次活动预算大概多少？" → "大概【数字】万，明细晚点发你"
        - 领导说"明早的会你来讲下方案" → "好的，我准备一下"
        - 同事问"文档发你了，看下有没有问题？" → "好，我看下"
        - 朋友问"周末有空吃饭吗？" → "有空啊，去哪吃"
        - 领导说"周报周五前交一下" → "好的，周五前交"

        \(RecordNote.text)

        只输出 JSON：{"replies":[{"id":1,"reply":"..."}]}
        """
    }

    static func user(items: [ActionItem], context: (ActionItem) -> [ArchivedMessage] = { _ in [] }) -> String {
        items.enumerated().map { index, item in
            let history = context(item)
            var block = """
            [\(index + 1)] 来自：\(item.sourceTitle)
            消息：\(item.sourceExcerpt.replacingOccurrences(of: "\n", with: " "))
            他需要做的事：\(item.summary)
            """
            if !history.isEmpty {
                block += "\n最近的聊天记录（旧→新）：\n" + ConversationArchive.transcript(history)
            }
            return block
        }.joined(separator: "\n\n")
    }

    static let schema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["replies"],
      "properties": {
        "replies": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "reply"],
            "properties": {
              "id": {"type": "integer"},
              "reply": {"type": "string"}
            }
          }
        }
      }
    }
    """
}
