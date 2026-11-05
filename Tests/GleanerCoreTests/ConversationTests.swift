import Foundation
import Testing
@testable import GleanerCore

/// Replays scripted replies, one per `streamChat` call, and records what it was sent.
final class ScriptedChatProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[ChatStreamEvent]]
    private(set) var calls: [(messages: [ChatMessage], allowTools: Bool, toolCount: Int)] = []

    init(_ replies: [[ChatStreamEvent]]) { self.replies = replies }

    func complete(_ request: CompletionRequest) async throws -> String { "" }

    func streamChat(_ messages: [ChatMessage], tools: [ToolSpec], allowTools: Bool) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let reply: [ChatStreamEvent] = lock.withLock {
            calls.append((messages, allowTools, tools.count))
            return replies.isEmpty ? [.text("（无）")] : replies.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            reply.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

struct StubSearch: WebSearchService {
    let results: [WebResult]
    func search(_ query: String, question: String) async throws -> [WebResult] { results }
}

@Suite struct ConversationTests {
    private func collect(_ stream: AsyncThrowingStream<Assistant.Event, Error>) async throws -> [Assistant.Event] {
        var events: [Assistant.Event] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func parserAssemblesToolCallFragments() {
        var parser = ChatStreamParser()
        let lines = [
            #"data: {"choices":[{"delta":{"reasoning_content":"想想"}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"web_search","arguments":"{\"qu"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ery\":\"上证指数\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"content":"好"}}]}"#,
            "data: [DONE]",
        ]
        let text = lines.compactMap { parser.consume($0) }.joined()
        #expect(text == "好")
        #expect(parser.reasoning == "想想")
        #expect(parser.toolCalls == [ToolCall(id: "call_1", name: "web_search", arguments: #"{"query":"上证指数"}"#)])
        #expect(parser.toolCalls.first?.argument("query") == "上证指数")
    }

    @Test func encodesToolMessages() {
        let call = ToolCall(id: "c1", name: "web_search", arguments: "{}")
        let assistant = OpenAICompatibleProvider.encode(ChatMessage(role: .assistant, content: "", toolCalls: [call], reasoning: "r"))
        #expect((assistant["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "c1")
        #expect(assistant["reasoning_content"] as? String == "r")
        let tool = OpenAICompatibleProvider.encode(ChatMessage(role: .tool, content: "结果", toolCallID: "c1"))
        #expect(tool["tool_call_id"] as? String == "c1")
        #expect(tool["role"] as? String == "tool")
    }

    @Test func parsesDeepSeekSearchResults() throws {
        let json = #"{"results":[{"title":"沪指收涨","url":"https://a.example","snippet":"短","summary":"长摘要","site_name":"财经网","date":"2026-11-05T07:00:00+00:00","rerank_score":2.1,"authority":3},{"title":"无摘要","url":"https://b.example","snippet":"只有片段","summary":""}]}"#
        let results = try DeepSeekWebSearch.results(from: Data(json.utf8))
        #expect(results.count == 2)
        #expect(results[0] == WebResult(title: "沪指收涨", url: "https://a.example", site: "财经网",
                                        date: "2026-11-05T07:00:00+00:00", summary: "长摘要"))
        #expect(results[1].summary == "只有片段")
    }

    @Test func searchesThenAnswersWithHistory() async throws {
        let provider = ScriptedChatProvider([
            [.toolCalls([ToolCall(id: "c1", name: "web_search", arguments: #"{"query":"上证指数 收盘"}"#)], reasoning: nil)],
            [.text("收于 3686 点"), .text("（财经网）")],
        ])
        let search = StubSearch(results: [WebResult(title: "沪指收涨", url: "u", site: "财经网", date: "2026-11-05", summary: "3686 点")])
        let history = [ChatTurn(question: "你好", answer: "在"), ChatTurn(question: "失败的", failed: true)]
        let assistant = Assistant(provider: provider)
        let context = assistant.conversationContext(messages: [], openItems: [], canSearch: true, appName: { $0 })
        let events = try await collect(assistant.converse(ChatTurn(question: "上证收盘多少"), history: history,
                                                          context: context, search: search))

        #expect(events == [.searching("上证指数 收盘"), .text("收于 3686 点"), .text("（财经网）")])
        #expect(provider.calls.count == 2)
        // History: system, earlier turn (failed ones dropped), the question.
        let first = provider.calls[0].messages.map(\.role)
        #expect(first == [.system, .user, .assistant, .user])
        // The second call carries the tool call and its result.
        let second = provider.calls[1].messages
        #expect(second.last?.role == .tool)
        #expect(second.last?.content.contains("3686 点") == true)
        #expect(provider.calls[0].messages[0].content.contains("联网搜索"))
    }

    @Test func stopsSearchingAfterTheRoundLimit() async throws {
        let call = ToolCall(id: "c", name: "web_search", arguments: #"{"query":"q"}"#)
        let provider = ScriptedChatProvider([
            [.toolCalls([call], reasoning: nil)],
            [.toolCalls([call], reasoning: nil)],
            [.text("答案")],
        ])
        let events = try await collect(Assistant(provider: provider).converse(
            ChatTurn(question: "问"), history: [], context: "c", search: StubSearch(results: [])))
        #expect(events.last == .text("答案"))
        #expect(provider.calls.map(\.allowTools) == [true, true, false])
        #expect(provider.calls.last?.messages.last?.role == .user)
    }

    @Test func withoutSearchNoToolsAreOffered() async throws {
        let provider = ScriptedChatProvider([[.text("好")]])
        let assistant = Assistant(provider: provider)
        let context = assistant.conversationContext(messages: [], openItems: [], canSearch: false, appName: { $0 })
        _ = try await collect(assistant.converse(ChatTurn(question: "问"), history: [], context: context, search: nil))
        #expect(provider.calls.first?.toolCount == 0)
        #expect(provider.calls.first?.messages.first?.content.contains("联网搜索") == false)
    }

    @Test func singleTurnProvidersGetTheConversationAsText() async throws {
        let provider = StubProvider([.success("好的")])
        let events = try await collect(Assistant(provider: provider).converse(
            ChatTurn(question: "那他呢"), history: [ChatTurn(question: "王总说了什么", answer: "要报价单")],
            context: "c", search: nil))
        #expect(events == [.text("好的")])
        let user = try #require(provider.receivedRequests.first?.user)
        #expect(user.contains("王总说了什么"))
        #expect(user.contains("那他呢"))
    }

    @Test func cleanDropsLeakedToolMarkup() {
        #expect(Assistant.clean("<｜｜DSML｜｜ calls>") == "")
        #expect(Assistant.clean("收于 3686 点\n<｜DSML｜function_calls>") == "收于 3686 点")
    }

    @Test func storageDropsEmptySessionsAndKeepsRecent() {
        var old = ChatSession(turns: [ChatTurn(question: "旧")], createdAt: Date(timeIntervalSince1970: 0))
        old.updatedAt = Date(timeIntervalSince1970: 0)
        let recent = ChatSession(turns: [ChatTurn(question: "新\n问题")])
        let kept = [old, ChatSession(), recent].trimmedForStorage(limit: 1)
        #expect(kept.map(\.id) == [recent.id])
        #expect(kept.first?.title == "新 问题")
    }

    @Test func searchKeyResolution() {
        let deepseek = ProviderConfiguration(apiProtocol: .openAICompatible, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let openai = ProviderConfiguration(apiProtocol: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt")
        let anthropic = ProviderConfiguration(apiProtocol: .anthropic, baseURL: "https://api.anthropic.com", model: "claude")
        func key(_ service: WebSearchService?) -> String? {
            (service as? DeepSeekWebSearch)?.apiKey ?? (service as? BaiduWebSearch)?.apiKey
        }

        // A DeepSeek model shares its key with DeepSeek search unless a separate one is set.
        #expect(key(deepseek.makeWebSearch(channel: .deepseek, channelKey: "", modelKey: "m")) == "m")
        #expect(key(deepseek.makeWebSearch(channel: .deepseek, channelKey: " s ", modelKey: "m")) == "s")
        // Baidu always needs its own key.
        #expect(deepseek.makeWebSearch(channel: .baidu, channelKey: "", modelKey: "m") == nil)
        #expect(deepseek.makeWebSearch(channel: .baidu, channelKey: "b", modelKey: "m") is BaiduWebSearch)
        // Other models' keys never go to a search service.
        #expect(openai.makeWebSearch(channel: .deepseek, channelKey: "", modelKey: "m") == nil)
        #expect(key(openai.makeWebSearch(channel: .deepseek, channelKey: "s", modelKey: "m")) == "s")
        // Models that cannot call tools get no search.
        #expect(anthropic.makeWebSearch(channel: .baidu, channelKey: "b", modelKey: "m") == nil)
    }

    @Test func nativeSearchVendors() {
        func config(_ proto: APIProtocol, _ url: String) -> ProviderConfiguration {
            ProviderConfiguration(apiProtocol: proto, baseURL: url, model: "m")
        }
        #expect(config(.anthropic, "https://api.anthropic.com").hasNativeWebSearch)
        #expect(config(.openAICompatible, "https://dashscope.aliyuncs.com/compatible-mode/v1").hasNativeWebSearch)
        #expect(config(.openAICompatible, "https://ws1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1").hasNativeWebSearch)
        #expect(!config(.openAICompatible, "https://api.deepseek.com").hasNativeWebSearch)
        #expect(!config(.anthropic, "https://proxy.example.com").hasNativeWebSearch)
    }

    @Test func anthropicAnswerSkipsTextBeforeSearching() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "我来搜一下。"],
            ["type": "server_tool_use", "id": "s", "name": "web_search"],
            ["type": "web_search_tool_result", "tool_use_id": "s", "content": []],
            ["type": "text", "text": "收于 "], ["type": "text", "text": "3686 点"],
        ]
        #expect(AnthropicProvider.answerText(from: content) == "收于 3686 点")
        #expect(AnthropicProvider.answerText(from: [["type": "text", "text": "直接回答"]]) == "直接回答")
    }

    @Test func anthropicResumesAfterPauseTurn() async throws {
        let http = MockHTTPClient(responses: [
            (200, #"{"stop_reason":"pause_turn","content":[{"type":"server_tool_use","id":"s","name":"web_search","input":{"query":"q"}}]}"#),
            (200, #"{"stop_reason":"end_turn","content":[{"type":"web_search_tool_result","tool_use_id":"s","content":[]},{"type":"text","text":"答案"}]}"#),
        ])
        let provider = AnthropicProvider(baseURL: "https://api.anthropic.com", model: "claude-sonnet-5-5", apiKey: "k",
                                         webSearch: true, http: http)
        let text = try await provider.complete(CompletionRequest(system: "s", user: "问"))
        #expect(text == "答案")
        #expect(http.requests.count == 2)
        let tools = http.requests[0].body["tools"] as? [[String: Any]]
        #expect(tools?.first?["type"] as? String == "web_search_20260209")
        let resent = http.requests[1].body["messages"] as? [[String: Any]]
        #expect(resent?.last?["role"] as? String == "assistant")
    }

    @Test func qwenSearchFlag() {
        let qwen = ProviderConfiguration(apiProtocol: .openAICompatible, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus")
        #expect((qwen.makeProvider(apiKey: "k", webSearch: true) as? OpenAICompatibleProvider)?.webSearch == true)
        let deepseek = ProviderConfiguration(apiProtocol: .openAICompatible, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        #expect((deepseek.makeProvider(apiKey: "k", webSearch: true) as? OpenAICompatibleProvider)?.webSearch == false)
    }

    @Test func parsesBaiduResults() throws {
        let json = #"{"request_id":"r","references":[{"id":1,"title":"北京天气","url":"https://w.example","website":"中国天气网","date":"2026-11-05 08:00:00","snippet":"晴","content":"今天晴，12 到 20 度","type":"web"},{"id":2,"title":"无正文","url":"https://x.example","snippet":"只有摘要"}]}"#
        let results = try BaiduWebSearch.results(from: Data(json.utf8), status: 200)
        #expect(results.map(\.title) == ["北京天气", "无正文"])
        #expect(results[0].site == "中国天气网")
        #expect(results[0].summary == "今天晴，12 到 20 度")
        #expect(results[1].summary == "只有摘要")
    }

    @Test func reportsBaiduErrors() {
        let json = #"{"requestId":"r","code":"216003","message":"Authentication error"}"#
        #expect(throws: LLMError.http(status: 200, body: "Authentication error")) {
            try BaiduWebSearch.results(from: Data(json.utf8), status: 200)
        }
    }

    @Test func baiduQueriesFitTheLimit() {
        #expect(BaiduWebSearch.truncated(String(repeating: "天", count: 50)).count == 36)
        #expect(BaiduWebSearch.truncated("weather 北京") == "weather 北京")
    }
}

@Suite struct AnswerTextTests {
    @Test func marksTrailingSources() {
        let line = "他只说下午有空（微信，李明，11-05 07:51），没有说明要聊什么。"
        #expect(AnswerText.segments(line) == [
            .init("他只说下午有空"),
            .init("（微信，李明，11-05 07:51）", isSource: true),
            .init("，没有说明要聊什么。"),
        ])
        #expect(AnswerText.segments("沪指收于 3686 点 (东方财富)") == [
            .init("沪指收于 3686 点"), .init(" (东方财富)", isSource: true),
        ])
    }

    @Test func leavesOtherParenthesesAlone() {
        #expect(AnswerText.segments("周五（明天）下午开会，记得带电脑") == [.init("周五（明天）下午开会，记得带电脑")])
        #expect(AnswerText.segments("没有括号") == [.init("没有括号")])
        #expect(AnswerText.segments("小王问统计口径（是否含退款），结论按含退款算")
                == [.init("小王问统计口径（是否含退款），结论按含退款算")])
        #expect(AnswerText.segments("沪指小幅震荡（东方财富）。") == [.init("沪指小幅震荡"), .init("（东方财富）", isSource: true), .init("。")])
    }
}

@Suite struct AttachmentTests {
    @Test func sessionsFromBeforeAttachmentsStillLoad() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","turns":[],"createdAt":"2026-11-05T01:00:00Z","updatedAt":"2026-11-05T01:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ChatSession.self, from: Data(old.utf8)).attachments.isEmpty)
        let file = ChatAttachment.file(path: "/tmp/报价单.xlsx")
        #expect(file.title == "报价单.xlsx")
    }

    @Test func questionsCarryTheirAttachments() async throws {
        let provider = ScriptedChatProvider([[.text("好")]])
        let preamble = Assistant.preamble(attachments: [.init(title: "报价单.xlsx", text: "Q3 回款\t120", truncated: true)],
                                          appName: { $0 })
        let turn = ChatTurn(question: "第三季度回款多少", preamble: preamble)
        for try await _ in Assistant(provider: provider).converse(turn, history: [], context: "c", search: nil) {}
        let user = try #require(provider.calls.first?.messages.last?.content)
        #expect(user.contains("【报价单.xlsx】（较长，只提供了前面部分）"))
        #expect(user.contains("Q3 回款\t120"))
        #expect(user.hasSuffix("问题：第三季度回款多少"))
    }

    @Test func followUpsRepeatEarlierRequestsExactly() async throws {
        // The second request must start with exactly what the first sent, so the provider's
        // prompt cache can serve it.
        let provider = ScriptedChatProvider([[.text("一")], [.text("二")]])
        let assistant = Assistant(provider: provider)
        var first = ChatTurn(question: "王总找我什么事", preamble: "刚收到的消息（旧→新）：\n王总：报价单")
        for try await _ in assistant.converse(first, history: [], context: "上下文", search: nil) {}
        first.answer = "一"
        let second = ChatTurn(question: "那他什么时候要", preamble: "刚收到的消息（旧→新）：\n王总：今天下班前")
        for try await _ in assistant.converse(second, history: [first], context: "上下文", search: nil) {}

        func contents(_ call: Int) -> [String] { provider.calls[call].messages.map(\.content) }
        #expect(Array(contents(1).prefix(contents(0).count)) == contents(0))
        #expect(contents(1).count == contents(0).count + 2)
    }

    @Test func preambleOrdersNewMessagesOlderMatchesAndAttachments() {
        let message = ArchivedMessage(id: "1", appID: "a", title: "王总", body: "报价单", date: Date())
        let text = Assistant.preamble(attachments: [.init(title: "合同.docx", text: "第一条")], newMessages: [message],
                                      earlier: [message], appName: { _ in "微信" })
        let order = ["刚收到的消息", "更早的相关消息", "【合同.docx】"].map { text.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(order[0]! < order[1]! && order[1]! < order[2]!)
        #expect(Assistant.preamble(attachments: [], appName: { $0 }).isEmpty)
    }

    @Test func parsesCacheUsage() {
        var deepseek = ChatStreamParser()
        _ = deepseek.consume(#"data: {"choices":[],"usage":{"prompt_tokens":1200,"prompt_cache_hit_tokens":1024,"prompt_cache_miss_tokens":176}}"#)
        #expect(deepseek.usage == PromptUsage(promptTokens: 1200, cachedTokens: 1024))
        var openai = ChatStreamParser()
        _ = openai.consume(#"data: {"choices":[],"usage":{"prompt_tokens":900,"prompt_tokens_details":{"cached_tokens":768}}}"#)
        #expect(openai.usage == PromptUsage(promptTokens: 900, cachedTokens: 768))
    }

    @Test func turnsFromBeforeAttachmentsStillLoad() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","question":"问","answer":"答"}"#
        let turn = try JSONDecoder().decode(ChatTurn.self, from: Data(old.utf8))
        #expect(turn.attachments.isEmpty && turn.preamble.isEmpty && turn.message == "问")
    }

    @Test func fileSummaryPrompt() {
        let request = Assistant(provider: StubProvider([])).fileSummaryRequest(
            named: "合同.docx", content: .init(text: "第一条", truncated: true))
        #expect(request.user.contains("文件名：合同.docx"))
        #expect(request.user.contains("只是前面部分"))
        #expect(request.system.contains("需要用户做的事"))
    }
}

@Suite struct NewsInContextTests {
    @Test func contextListsCuratedNewsNewestFirst() {
        func news(_ headline: String, minutesAgo: Double) -> NewsItem {
            NewsItem(headline: headline, category: .finance, appID: "com.eastmoney", origin: .mac, sourceTitle: "东方财富",
                     sourceExcerpt: "", date: Date().addingTimeInterval(-minutesAgo * 60))
        }
        let context = Assistant(provider: StubProvider([])).conversationContext(
            messages: [], openItems: [], news: [news("光伏板块大涨", minutesAgo: 30), news("央行下调利率", minutesAgo: 5)],
            canSearch: false, appName: { _ in "东方财富" })
        #expect(context.contains("热点（已整理，新→旧）"))
        let newer = context.range(of: "央行下调利率")!.lowerBound
        let older = context.range(of: "光伏板块大涨")!.lowerBound
        #expect(newer < older)
        #expect(context.contains("问到热点、新闻、行情时"))
    }
}
