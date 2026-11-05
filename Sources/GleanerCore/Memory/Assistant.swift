import Foundation

/// Answers about recent messages: conversation summaries and free-form questions.
public struct Assistant: Sendable {
    public var provider: LLMProvider
    public var userNames: [String]

    public init(provider: LLMProvider, userNames: [String] = []) {
        self.provider = provider
        self.userNames = userNames
    }

    /// A few short lines on what a conversation was about, and what concerns the user.
    /// `gaps` are lines from `ForegroundHistory.describe` for stretches the record may be missing.
    public func summarize(_ messages: [ArchivedMessage], conversation: String, gaps: [String] = []) -> AsyncThrowingStream<String, Error> {
        provider.stream(summaryRequest(messages, conversation: conversation, gaps: gaps))
    }

    /// Older messages found by searching the archive for the question.
    static func earlierNote(_ messages: [ArchivedMessage], appName: (String) -> String) -> String {
        guard !messages.isEmpty else { return "" }
        return """


        更早的相关消息（按问题检索，旧→新）：
        \(ConversationArchive.transcript(messages, includeConversation: true, appName: appName))
        """
    }

    /// Tells the model where the record may have holes, so silence isn't read as nothing said.
    static func gapNote(_ gaps: [String]) -> String {
        guard !gaps.isEmpty else { return "" }
        return """


        记录可能不全：以下时段用户正开着这些应用，期间的消息没有被记录。
        \(gaps.joined(separator: "\n"))
        """
    }

    /// Material a question is about, already read into text.
    public struct Attachment: Sendable, Equatable {
        public var title: String
        public var text: String
        /// Only the beginning of a long file is included.
        public var truncated: Bool

        public init(title: String, text: String, truncated: Bool = false) {
            self.title = title
            self.text = text
            self.truncated = truncated
        }
    }

    /// Key points of a received file.
    public func summarizeFile(named name: String, content: FileTextExtractor.Content) -> AsyncThrowingStream<String, Error> {
        provider.stream(fileSummaryRequest(named: name, content: content))
    }

    func fileSummaryRequest(named name: String, content: FileTextExtractor.Content) -> CompletionRequest {
        let system = """
        总结用户收到的文件，让用户快速知道它讲了什么、要不要处理。用户的称呼：\(names)。
        - 3 到 5 行，每行一句，以"- "开头
        - 先说这是什么文件，再写关键数字、日期和结论
        - 有需要用户做的事（填写、回复、审批、截止时间），单独一行写清楚
        - 不要开场白，不要使用"·"符号
        """
        let note = content.truncated ? "（文件较长，以下只是前面部分）\n" : ""
        return CompletionRequest(system: system, user: "文件名：\(name)\n\(note)\n\(content.text)")
    }

    static func attachmentNote(_ attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        let blocks = attachments.map { attachment in
            let note = attachment.truncated ? "（较长，只提供了前面部分）" : ""
            return "【\(attachment.title)】\(note)\n\(attachment.text)"
        }.joined(separator: "\n\n")
        return "\n\n用户就下面的内容提问，回答以它为准：\n" + blocks
    }

    public enum Event: Sendable, Equatable {
        /// A web search started, with its query.
        case searching(String)
        case text(String)
        /// Prompt tokens of a request and how many came from the provider's cache.
        case usage(PromptUsage)
    }

    /// How many earlier turns are sent back with a follow-up question. Generous on purpose:
    /// dropping the oldest turn changes the start of the request and loses the prompt cache.
    public static let historyTurns = 30
    /// Rounds of tool use before the model must answer.
    static let maxSearchRounds = 2

    /// The fixed part of a conversation: instructions, open items and recent messages as of its
    /// first question. Built once and reused, so every later request starts the same way.
    public func conversationContext(messages: [ArchivedMessage], openItems: [ActionItem], news: [NewsItem] = [],
                                    canSearch: Bool, gaps: [String] = [], now: Date = Date(),
                                    appName: (String) -> String) -> String {
        conversationSystem(messages: messages, openItems: openItems, news: news, canSearch: canSearch, now: now,
                           appName: appName)
            + Self.gapNote(gaps)
    }

    /// How many news headlines go into a conversation's context.
    static let newsLimit = 40

    /// What goes ahead of one question: its attachments, messages that arrived since the
    /// conversation began, and older messages found for it.
    public static func preamble(attachments: [Attachment], newMessages: [ArchivedMessage] = [],
                                earlier: [ArchivedMessage] = [], appName: (String) -> String) -> String {
        var parts: [String] = []
        if !newMessages.isEmpty {
            parts.append("刚收到的消息（旧→新）：\n" + ConversationArchive.transcript(newMessages, includeConversation: true, appName: appName))
        }
        let earlierText = earlierNote(earlier, appName: appName)
        if !earlierText.isEmpty { parts.append(earlierText.trimmingCharacters(in: .newlines)) }
        let attached = attachmentNote(attachments)
        if !attached.isEmpty { parts.append(attached.trimmingCharacters(in: .newlines)) }
        return parts.joined(separator: "\n\n")
    }

    /// Answers `turn` (its question and preamble) after `history`, starting from `context`.
    /// Earlier turns are replayed exactly as first sent, so the request only grows at the end.
    /// The model may search the web through `search`, or by itself when `nativeSearch`.
    public func converse(_ turn: ChatTurn, history: [ChatTurn], context: String,
                         search: WebSearchService?, nativeSearch: Bool = false) -> AsyncThrowingStream<Event, Error> {
        let earlier = history.filter { !$0.failed && !$0.answer.isEmpty }.suffix(Self.historyTurns)
        let question = turn.question

        guard let tooling = provider as? ToolCallingProvider else {
            // Single-turn providers get the conversation so far as text.
            let past = earlier.map { "用户：\($0.message)\n助理：\($0.answer)" }.joined(separator: "\n\n")
            let user = past.isEmpty ? turn.message : "之前的对话：\n\(past)\n\n现在：\(turn.message)"
            let stream = provider.stream(CompletionRequest(system: context, user: user))
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await piece in stream { continuation.yield(.text(piece)) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        var opening: [ChatMessage] = [.system(context)]
        for past in earlier { opening += [.user(past.message), .assistant(past.answer)] }
        opening.append(.user(turn.message))
        let start = opening
        let tools = search == nil ? [] : [Self.webSearchTool]

        return AsyncThrowingStream { continuation in
            let task = Task {
                var conversation = start
                do {
                    var round = 0
                    while true {
                        let allowTools = !tools.isEmpty && round < Self.maxSearchRounds
                        if !tools.isEmpty && !allowTools {
                            // Some models keep trying to call tools when told not to; ask plainly.
                            conversation.append(.user("不要再搜索，直接根据以上搜索结果回答我的问题。"))
                        }
                        var text = ""
                        var calls: [ToolCall] = []
                        var reasoning: String?
                        for try await event in tooling.streamChat(conversation, tools: tools, allowTools: allowTools) {
                            switch event {
                            case .text(let piece):
                                text += piece
                                continuation.yield(.text(piece))
                            case .usage(let usage):
                                continuation.yield(.usage(usage))
                            case .toolCalls(let requested, let thought):
                                calls = requested
                                reasoning = thought
                            }
                        }
                        guard !calls.isEmpty, let search, allowTools else { break }
                        conversation.append(ChatMessage(role: .assistant, content: text, toolCalls: calls, reasoning: reasoning))
                        for call in calls {
                            let query = call.argument("query")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            var result = "没有找到结果"
                            if !query.isEmpty {
                                continuation.yield(.searching(query))
                                if let found = try? await search.search(query, question: question), !found.isEmpty {
                                    result = Self.describe(found)
                                }
                            }
                            conversation.append(ChatMessage(role: .tool, content: result, toolCallID: call.id))
                        }
                        round += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let webSearchTool = ToolSpec(
        name: "web_search",
        description: "搜索互联网。问题涉及新闻、行情、天气、公开资料等实时或外部信息，而消息记录里没有时使用。",
        parameters: #"{"type":"object","properties":{"query":{"type":"string","description":"搜索关键词，简短具体"}},"required":["query"]}"#
    )

    /// Search results as the model reads them.
    static func describe(_ results: [WebResult]) -> String {
        results.enumerated().map { index, result in
            let source = [result.site, result.date.map { String($0.prefix(10)) }].compactMap { $0 }.joined(separator: "，")
            return "\(index + 1). \(result.title)（\(source)）\n\(result.summary)"
        }.joined(separator: "\n\n")
    }

    func conversationSystem(messages: [ArchivedMessage], openItems: [ActionItem], news: [NewsItem] = [], canSearch: Bool,
                            now: Date, appName: (String) -> String) -> String {
        let today = now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().weekday(.wide))
        let items = openItems.map { "- \($0.summary)（\(appName($0.appID))，\($0.sourceTitle)）" }.joined(separator: "\n")
        let time = DateFormatter()
        time.dateFormat = "MM-dd HH:mm"
        let headlines = news.sorted { $0.date > $1.date }.prefix(Self.newsLimit).map {
            "- \($0.headline)（\($0.category.displayName)，\(appName($0.appID))，\(time.string(from: $0.date))）"
        }.joined(separator: "\n")
        let searchRule = canSearch
            ? "\n- 消息记录里没有、需要实时或外部信息时（新闻、行情、天气等），先联网搜索再回答，句末注明来源网站"
            : ""
        return """
        你是用户的助理。今天是\(today)。用户的称呼：\(names)。
        - 先根据下面的消息记录和待办回答；记录里找不到就直说\(searchRule)
        - 问到热点、新闻、行情时，先用下面"热点"里已整理的内容，不够再补充
        - 简短直接，一般不超过 6 行；列举时每行以"- "开头，涉及消息时在句末用括号注明是谁、在哪个会话，如（微信，王总，11-05 09:30）
        - 不要使用"·"符号
        - 引用原话用「」，重点可用 **加粗**，不用标题和表格
        - 你只能回答问题，不能替用户发消息或操作，不要问"要不要我…"
        - 问到的事若落在下面"记录可能不全"的时段，说明那段记录可能缺失
        - 不要开场白和客套话

        待办：
        \(items.isEmpty ? "无" : items)

        热点（已整理，新→旧）：
        \(headlines.isEmpty ? "无" : headlines)

        最近的消息（旧→新）：
        \(ConversationArchive.transcript(messages, includeConversation: true, appName: appName))
        """
    }

    func summaryRequest(_ messages: [ArchivedMessage], conversation: String, gaps: [String] = []) -> CompletionRequest {
        let gapRule = gaps.isEmpty ? "" : "\n- 记录有缺失时段：不要把缺失当成没人说话；最后一行写\"- 部分时段记录缺失\""
        let system = """
        总结下面这段聊天记录，给用户快速了解。用户的称呼：\(names)。
        - 最多 5 行，每行一句，不超过 30 字，以"- "开头；不要使用"·"符号
        - 先写和用户有关的事（找他、问他、需要他做的），再写其他要点
        - 不要寒暄、不要评价、不要多余的开场白\(gapRule)
        """ + Self.gapNote(gaps)
        return CompletionRequest(system: system, user: "会话：\(conversation)\n\n" + ConversationArchive.transcript(messages))
    }

    /// Drops a reasoning preamble and surrounding whitespace from streamed or complete output.
    public static func clean(_ output: String) -> String {
        var text = output
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        else if text.hasPrefix("<think>") { return "" }
        // Tool-call markup some models leak as text (e.g. DeepSeek's "<｜DSML｜…>") is not an answer.
        if let markup = text.range(of: "<｜") { text = String(text[..<markup.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var names: String { userNames.isEmpty ? "未设置" : userNames.joined(separator: "、") }
}
