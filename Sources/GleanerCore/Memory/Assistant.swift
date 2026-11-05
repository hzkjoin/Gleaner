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

    /// Parts a long file is summarized in at most; beyond that only the start is covered.
    static let summaryParts = 20

    /// Key points of a received file. A file longer than `partSize` characters is summarized part
    /// by part, then the parts' points are put together; only the final summary streams.
    public func summarizeFile(named name: String, content: FileTextExtractor.Content,
                              partSize: Int = 20_000) -> AsyncThrowingStream<String, Error> {
        guard content.text.count > partSize else {
            return provider.stream(fileSummaryRequest(named: name, content: content))
        }
        let parts = DocumentSections(text: content.text, size: partSize).sections
        let covered = Array(parts.prefix(Self.summaryParts))
        let partial = content.truncated || parts.count > covered.count
        let provider = provider
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let points = try await Self.partPoints(covered, name: name, provider: provider)
                    let notes = points.enumerated().map { "【第 \($0.offset + 1) 部分】\n\($0.element)" }.joined(separator: "\n\n")
                    let merged = FileTextExtractor.Content(text: "以下是文件各部分的要点：\n\n" + notes, truncated: partial)
                    for try await piece in provider.stream(fileSummaryRequest(named: name, content: merged)) {
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Points of each part, four requests at a time, in order.
    static func partPoints(_ parts: [String], name: String, provider: LLMProvider) async throws -> [String] {
        let system = """
        下面是一份文件的其中一部分。提取这部分的要点：讲了什么，关键数字、日期、结论，需要谁做什么。
        - 不超过 6 行，每行以"- "开头
        - 没有实质内容就只写一行"- 无要点"
        - 不要开场白，不要使用"·"符号
        """
        var results = Array(repeating: "", count: parts.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func add() {
                guard next < parts.count else { return }
                let index = next
                next += 1
                group.addTask {
                    let request = CompletionRequest(system: system,
                                                    user: "文件名：\(name)，第 \(index + 1)/\(parts.count) 部分\n\n\(parts[index])")
                    return (index, clean(try await provider.complete(request)))
                }
            }
            for _ in 0..<4 { add() }
            while let (index, text) = try await group.next() {
                results[index] = text
                add()
            }
        }
        return results
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
        /// An attached file was read or searched, as "报告.pdf 第 5 段" or "报告.pdf 搜索「预算」".
        case reading(String)
    }

    /// How many earlier turns are sent back with a follow-up question. Generous on purpose:
    /// dropping the oldest turn changes the start of the request and loses the prompt cache.
    public static let historyTurns = 30
    /// Rounds of web searches before the model must answer.
    static let maxSearchRounds = 2
    /// File sections the model may read for one question.
    static let maxReads = 4
    /// Keyword searches in attached files for one question.
    static let maxFileSearches = 4
    /// Rounds of tool use of any kind before the model must answer.
    static let maxToolRounds = 6

    /// The user messages to send for `earlier` turns: as first sent, or shortened oldest first
    /// while the whole request would pass `limit` characters.
    static func fit(_ earlier: [ChatTurn], current: ChatTurn, context: String, limit: Int) -> [String] {
        var messages = earlier.map(\.message)
        var total = context.count + current.message.count + earlier.reduce(0) { $0 + $1.message.count + $1.answer.count }
        for index in earlier.indices where total > limit {
            let short = earlier[index].shortMessage
            total -= messages[index].count - short.count
            messages[index] = short
        }
        return messages
    }

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
    /// When the request would pass `budget.conversation` characters, the oldest turns' preambles
    /// are left out (questions and answers stay) until it fits.
    /// `files` are long attached files by name, whose other sections the model may read.
    public func converse(_ turn: ChatTurn, history: [ChatTurn], context: String,
                         search: WebSearchService?, nativeSearch: Bool = false,
                         budget: ContextBudget = ContextBudget(contextTokens: 128_000),
                         files: [String: DocumentSections] = [:]) -> AsyncThrowingStream<Event, Error> {
        let earlier = history.filter { !$0.failed && !$0.answer.isEmpty }.suffix(Self.historyTurns)
        let messages = Self.fit(Array(earlier), current: turn, context: context, limit: budget.conversation)
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
        for (past, message) in zip(earlier, messages) { opening += [.user(message), .assistant(past.answer)] }
        opening.append(.user(turn.message))
        let start = opening
        let tools = (search == nil ? [] : [Self.webSearchTool]) + (files.isEmpty ? [] : [Self.searchFileTool, Self.readFileTool])

        return AsyncThrowingStream { continuation in
            let task = Task {
                var conversation = start
                do {
                    var round = 0
                    var searchRounds = 0
                    var reads = 0
                    var fileSearches = 0
                    while true {
                        let canSearch = search != nil && searchRounds < Self.maxSearchRounds
                        let canRead = !files.isEmpty && (reads < Self.maxReads || fileSearches < Self.maxFileSearches)
                        let allowTools = round < Self.maxToolRounds && (canSearch || canRead)
                        if !tools.isEmpty && !allowTools {
                            // Some models keep trying to call tools when told not to; ask plainly.
                            conversation.append(.user("不要再搜索或读取，直接根据以上内容回答我的问题。"))
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
                        guard !calls.isEmpty, allowTools else { break }
                        conversation.append(ChatMessage(role: .assistant, content: text, toolCalls: calls, reasoning: reasoning))
                        var searched = false
                        for call in calls {
                            var result: String
                            // Tool results never take the request past the conversation budget.
                            let room = budget.conversation - conversation.reduce(0) { $0 + $1.content.count }
                            if call.name == Self.searchFileTool.name {
                                result = Self.searchFiles(call, in: files, searchesSoFar: fileSearches, room: room)
                                if !result.hasPrefix("（") || result.hasPrefix("（没有找到") {
                                    fileSearches += 1
                                    continuation.yield(.reading(Self.searchLabel(call, in: files)))
                                }
                            } else if call.name == Self.readFileTool.name {
                                result = Self.read(call, in: files, readsSoFar: reads, room: room)
                                if let label = Self.readLabel(call, in: files), !result.hasPrefix("（") {
                                    reads += 1
                                    continuation.yield(.reading(label))
                                }
                            } else if let search, searchRounds < Self.maxSearchRounds {
                                searched = true
                                result = "没有找到结果"
                                let query = call.argument("query")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                if room < Self.minimumRoom {
                                    result = Self.contextFull
                                } else if !query.isEmpty {
                                    continuation.yield(.searching(query))
                                    if let found = try? await search.search(query, question: question), !found.isEmpty {
                                        result = Self.describe(found, room: room) ?? Self.contextFull
                                    }
                                }
                            } else {
                                result = "（不能再搜索，请根据已有内容回答）"
                            }
                            conversation.append(ChatMessage(role: .tool, content: result, toolCallID: call.id))
                        }
                        if searched { searchRounds += 1 }
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

    static let readFileTool = ToolSpec(
        name: "read_file",
        description: "读取用户引用的长文件的某一段。只在已提供的内容不够回答时使用，根据目录挑相关的段。",
        parameters: #"{"type":"object","properties":{"file":{"type":"string","description":"文件名"},"section":{"type":"integer","description":"段号，从 1 开始"}},"required":["file","section"]}"#
    )

    static let searchFileTool = ToolSpec(
        name: "search_file",
        description: "在用户引用的长文件里搜索关键词，返回包含关键词的行（带行号、所在段号和前后各一行）。想找某个数字、名字、条款时先用它，再按段号用 read_file 读全段。",
        parameters: #"{"type":"object","properties":{"file":{"type":"string","description":"文件名，不填则搜索所有文件"},"keywords":{"type":"string","description":"关键词，多个用空格分开，任一出现即算匹配"}},"required":["keywords"]}"#
    )

    /// Lines most shown for one search.
    static let searchLineLimit = 30

    /// "报告.pdf 搜索「预算 审批」"
    static func searchLabel(_ call: ToolCall, in files: [String: DocumentSections]) -> String {
        let keywords = call.argument("keywords")?.trimmingCharacters(in: .whitespaces) ?? ""
        let named = call.argument("file").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        // Without a file, all are searched: name the only one, or none.
        let name = named.flatMap { file(named: $0, in: files)?.0 } ?? (files.count == 1 ? files.first?.key : nil)
        return name.map { "\($0) 搜索「\(keywords)」" } ?? "搜索「\(keywords)」"
    }

    /// The tool result for a `search_file` call: matching lines per file. Refusals are in parentheses.
    /// The result never passes `room` characters: lines are dropped from the end to fit.
    static func searchFiles(_ call: ToolCall, in files: [String: DocumentSections], searchesSoFar: Int,
                            room: Int = .max) -> String {
        guard searchesSoFar < maxFileSearches else { return "（这次已搜索 \(maxFileSearches) 次，不能再搜，请根据已有内容回答）" }
        guard room >= minimumRoom else { return contextFull }
        let keywords = (call.argument("keywords") ?? call.argument("query") ?? "")
            .split(whereSeparator: { " ,，、".contains($0) }).map(String.init)
        guard !keywords.isEmpty else { return "（请给出关键词）" }
        var targets = files.sorted { $0.key < $1.key }
        if let name = call.argument("file"), !name.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let found = file(named: name, in: files) else {
                return "（没有这个文件，可搜索的文件：\(files.keys.sorted().joined(separator: "、"))）"
            }
            targets = [found]
        }
        let lowered = keywords.map { $0.lowercased() }
        var blocks: [String] = []
        var used = 0
        for (name, document) in targets {
            let (lines, total) = document.search(keywords, limit: searchLineLimit)
            guard total > 0 else { continue }
            // Room for this file's heading, then lines while they fit.
            let headingRoom = 40 + name.count
            var body: [String] = []
            var shownHits = 0
            var length = 0
            for (index, match) in lines.enumerated() {
                var entry = "\(match.line) 行（第 \(match.section) 段）：\(match.text)"
                // A gap in line numbers starts a new group.
                if index > 0, match.line > lines[index - 1].line + 1 { entry = "…\n" + entry }
                guard used + headingRoom + length + entry.count + 1 <= room else { break }
                body.append(entry)
                length += entry.count + 1
                if lowered.contains(where: { match.text.lowercased().contains($0) }) { shownHits += 1 }
            }
            guard !body.isEmpty else { break }
            // Context lines after the last listed match may match too; they don't count.
            shownHits = min(shownHits, searchLineLimit)
            let more = shownHits < total ? (body.count < lines.count ? "，结果过多，只列出前 \(shownHits) 处" : "，只列出前 \(shownHits) 处") : ""
            let block = "〔\(name)〕共 \(total) 处\(more)\n" + body.joined(separator: "\n")
            blocks.append(block)
            used += block.count + 2
            if body.count < lines.count { break }
        }
        if blocks.isEmpty {
            // Matches that didn't fit at all.
            let anyMatch = targets.contains { $0.1.search(keywords, limit: 1).total > 0 }
            return anyMatch ? contextFull : "（没有找到包含「\(keywords.joined(separator: " "))」的内容）"
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Below this many characters of room, tools refuse instead of returning scraps.
    static let minimumRoom = 300
    static let contextFull = "（上下文已满，不能再读取或搜索，请根据已有内容回答）"

    /// Web results that fit in `room` characters, dropping the last ones first; nil if none fits.
    static func describe(_ results: [WebResult], room: Int) -> String? {
        var count = results.count
        while count > 0 {
            let text = describe(Array(results.prefix(count)))
            if text.count <= room { return text }
            count -= 1
        }
        return nil
    }

    /// The attached file a call names: by exact name, then by part of it, then the only one.
    static func file(named name: String, in files: [String: DocumentSections]) -> (String, DocumentSections)? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "「」《》\"'"))
        if let exact = files[name] { return (name, exact) }
        if let match = files.first(where: { !name.isEmpty && ($0.key.contains(name) || name.contains($0.key)) }) { return match }
        return files.count == 1 ? files.first : nil
    }

    /// "报告.pdf 第 5 段", for a call that names an existing section.
    static func readLabel(_ call: ToolCall, in files: [String: DocumentSections]) -> String? {
        guard let (name, document) = file(named: call.argument("file") ?? "", in: files),
              let number = call.integer("section"), document.section(number) != nil else { return nil }
        return "\(name) 第 \(number) 段"
    }

    /// The tool result for a `read_file` call. Refusals are in parentheses.
    static func read(_ call: ToolCall, in files: [String: DocumentSections], readsSoFar: Int, room: Int) -> String {
        guard readsSoFar < maxReads else { return "（这次已读取 \(maxReads) 段，不能再读，请根据已读内容回答）" }
        guard let (name, document) = file(named: call.argument("file") ?? "", in: files) else {
            return "（没有这个文件，可读取的文件：\(files.keys.sorted().joined(separator: "、"))）"
        }
        guard let number = call.integer("section"), let text = document.section(number) else {
            return "（段号应在 1 到 \(document.count) 之间）"
        }
        guard text.count + 40 < room else { return contextFull }
        return "〔\(name) 第 \(number) 段，共 \(document.count) 段〕\n\(text)"
    }

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
