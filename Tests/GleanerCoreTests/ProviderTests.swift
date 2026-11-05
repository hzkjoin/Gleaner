import Foundation
import Testing
@testable import GleanerCore

@Suite("Endpoint resolution")
struct EndpointTests {
    @Test("joins base URLs and paths", arguments: [
        ("http://127.0.0.1:11434/v1", "/chat/completions", "http://127.0.0.1:11434/v1/chat/completions"),
        ("https://api.deepseek.com/v1/", "/chat/completions", "https://api.deepseek.com/v1/chat/completions"),
        ("https://x.com/v1/chat/completions", "/chat/completions", "https://x.com/v1/chat/completions"),
        ("https://api.anthropic.com", "/v1/messages", "https://api.anthropic.com/v1/messages"),
        ("https://proxy.example.com/v1", "/v1/messages", "https://proxy.example.com/v1/messages"),
        (" https://proxy.example.com/v1/messages ", "/v1/messages", "https://proxy.example.com/v1/messages"),
    ])
    func joins(base: String, path: String, expected: String) throws {
        #expect(try HTTPSupport.endpoint(base: base, path: path).absoluteString == expected)
    }

    @Test("rejects URLs without scheme or host", arguments: ["", "api.example.com", "not a url"])
    func rejects(base: String) {
        #expect(throws: LLMError.self) { try HTTPSupport.endpoint(base: base, path: "/chat/completions") }
    }
}

@Suite("OpenAICompatibleProvider")
struct OpenAICompatibleProviderTests {
    let request = CompletionRequest(system: "sys", user: "hello", jsonSchema: "{}")

    static func reply(_ content: String) -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [content], options: [.fragmentsAllowed]), encoding: .utf8)!
        return #"{"choices":[{"message":{"role":"assistant","content":\#(escaped.dropFirst().dropLast())}}]}"#
    }

    @Test("sends a chat completion with JSON mode and bearer auth")
    func sendsRequest() async throws {
        let http = MockHTTPClient(responses: [(200, Self.reply("ok"))])
        let provider = OpenAICompatibleProvider(baseURL: "https://api.example.com/v1", model: "m", apiKey: "sk-1", http: http)

        #expect(try await provider.complete(request) == "ok")
        let sent = try #require(http.requests.first)
        #expect(sent.url.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(sent.headers["Authorization"] == "Bearer sk-1")
        #expect(sent.body["model"] as? String == "m")
        #expect((sent.body["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(sent.body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == "hello")
    }

    @Test("omits auth for keyless local servers")
    func keyless() async throws {
        let http = MockHTTPClient(responses: [(200, Self.reply("ok"))])
        let provider = OpenAICompatibleProvider(baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b", apiKey: "", http: http)
        _ = try await provider.complete(request)
        #expect(http.requests.first?.headers["Authorization"] == nil)
    }

    @Test("leaves reasoning to the model by default and turns it off on request")
    func reasoningSwitch() async throws {
        let http = MockHTTPClient(responses: [(200, Self.reply("ok")), (200, Self.reply("ok"))])
        _ = try await OpenAICompatibleProvider(baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b", apiKey: "", http: http)
            .complete(request)
        _ = try await OpenAICompatibleProvider(baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b", apiKey: "",
                                               reasoning: false, http: http).complete(request)
        #expect(http.requests[0].body["reasoning_effort"] == nil)
        #expect(http.requests[1].body["reasoning_effort"] as? String == "none")
        let messages = try #require(http.requests[1].body["messages"] as? [[String: String]])
        #expect(messages[1]["content"] == "hello")
    }

    @Test("does not send the reasoning switch to cloud vendors")
    func cloudKeepsReasoningAlone() async throws {
        let http = MockHTTPClient(responses: [(200, Self.reply("ok"))])
        _ = try await OpenAICompatibleProvider(baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKey: "k",
                                               reasoning: false, http: http).complete(request)
        #expect(http.requests.first?.body["reasoning_effort"] == nil)
        #expect(http.requests.first?.url.absoluteString == "https://api.deepseek.com/chat/completions")
    }

    @Test("drops optional parameters one at a time after a 400, keeping JSON mode longest")
    func retriesWithoutOptionalParameters() async throws {
        let http = MockHTTPClient(responses: [(400, "unknown reasoning_effort"), (200, Self.reply("ok"))])
        let provider = OpenAICompatibleProvider(baseURL: "http://127.0.0.1:11434/v1", model: "m", apiKey: "",
                                                reasoning: false, http: http)
        #expect(try await provider.complete(request) == "ok")
        #expect(http.requests.count == 2)
        #expect(http.requests[0].body["reasoning_effort"] != nil)
        #expect(http.requests[1].body["reasoning_effort"] == nil)
        #expect(http.requests[1].body["response_format"] != nil)

        let stubborn = MockHTTPClient(responses: [(400, "no"), (400, "no"), (200, Self.reply("ok"))])
        _ = try await OpenAICompatibleProvider(baseURL: "http://127.0.0.1:11434/v1", model: "m", apiKey: "",
                                               reasoning: false, http: stubborn).complete(request)
        #expect(stubborn.requests.count == 3 && stubborn.requests[2].body["response_format"] == nil)
    }

    @Test("surfaces HTTP errors with status and body")
    func surfacesErrors() async {
        let http = MockHTTPClient(responses: [(401, "invalid key")])
        let provider = OpenAICompatibleProvider(baseURL: "https://api.example.com/v1", model: "m", apiKey: "k", http: http)
        await #expect(throws: LLMError.http(status: 401, body: "invalid key")) { try await provider.complete(request) }
    }
}

@Suite("AnthropicProvider")
struct AnthropicProviderTests {
    let request = CompletionRequest(system: "sys", user: "hello", jsonSchema: ExtractionPrompt.schema)
    let okBody = #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"actions\":[]}"}]}"#

    @Test("uses structured outputs, low effort and fallbacks on the official API")
    func officialRequest() async throws {
        let http = MockHTTPClient(responses: [(200, okBody)])
        let provider = AnthropicProvider(baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", apiKey: "sk-ant", http: http)

        #expect(try await provider.complete(request) == #"{"actions":[]}"#)
        let sent = try #require(http.requests.first)
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.headers["x-api-key"] == "sk-ant")
        #expect(sent.headers["anthropic-version"] == AnthropicProvider.officialAPIVersion)
        #expect(sent.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        #expect(sent.body["fallbacks"] as? String == "default")
        // The system prompt is marked for prompt caching.
        let system = sent.body["system"] as? [[String: Any]]
        #expect(system?.first?["text"] as? String == "sys")
        #expect((system?.first?["cache_control"] as? [String: String])?["type"] == "ephemeral")
        let output = try #require(sent.body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "low")
        let format = try #require(output["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["schema"] is [String: Any])
    }

    @Test("omits fallbacks for models that do not support them")
    func noFallbacksForOtherModels() {
        let provider = AnthropicProvider(baseURL: "https://api.anthropic.com", model: "claude-haiku-5-5", apiKey: "k")
        let (headers, body) = provider.requestBody(for: request)
        #expect(headers["anthropic-beta"] == nil)
        #expect(body["fallbacks"] == nil)
        #expect(body["output_config"] != nil)
    }

    @Test("sends a plain request to third-party compatible endpoints")
    func compatibleRequest() {
        let provider = AnthropicProvider(baseURL: "https://api.example.com/anthropic", model: "some-model", apiKey: "k")
        let (headers, body) = provider.requestBody(for: request)
        #expect(headers["anthropic-version"] == AnthropicProvider.compatibleAPIVersion)
        #expect(headers["anthropic-beta"] == nil)
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
    }

    @Test("reports refusals")
    func refusal() async {
        let http = MockHTTPClient(responses: [(200, #"{"stop_reason":"refusal","content":[]}"#)])
        let provider = AnthropicProvider(baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", apiKey: "k", http: http)
        await #expect(throws: LLMError.refused) { try await provider.complete(request) }
    }
}

@Suite("ProviderConfiguration")
struct ProviderConfigurationTests {
    @Test("detects local endpoints")
    func local() {
        #expect(ProviderPreset.default.configuration.isLocal)
        #expect(!ProviderConfiguration(apiProtocol: .anthropic, baseURL: "https://api.anthropic.com", model: "m").isLocal)
        #expect(ProviderConfiguration(apiProtocol: .openAICompatible, baseURL: "http://localhost:8080/v1", model: "m").isLocal)
    }

    @Test("stores keys per host")
    func secretAccount() {
        let config = ProviderConfiguration(apiProtocol: .openAICompatible, baseURL: "https://api.deepseek.com/v1", model: "m")
        #expect(config.secretAccount == "api.deepseek.com")
    }

    @Test("decodes configurations saved before the reasoning switch existed")
    func decodesLegacy() throws {
        let json = #"{"apiProtocol":"openai","baseURL":"http://127.0.0.1:11434/v1","model":"qwen3:8b"}"#
        let config = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(json.utf8))
        #expect(config.reasoning)
        #expect(config.model == "qwen3:8b")
    }

    @Test("builds the provider matching the protocol")
    func makesProvider() {
        #expect(ProviderConfiguration(apiProtocol: .anthropic, baseURL: "https://a", model: "m")
            .makeProvider(apiKey: "") is AnthropicProvider)
        #expect(ProviderConfiguration(apiProtocol: .openAICompatible, baseURL: "https://a", model: "m")
            .makeProvider(apiKey: "") is OpenAICompatibleProvider)
    }
}

@Suite("Streaming")
struct StreamingTests {
    @Test("reads text pieces from chat-completions event lines", arguments: [
        (#"data: {"choices":[{"delta":{"content":"填表"}}]}"#, "填表"),
        (#"data:{"choices":[{"delta":{"role":"assistant"}}]}"#, nil),
        (#"data: {"choices":[{"delta":{"content":""}}]}"#, nil),
        ("data: [DONE]", nil),
        (": keep-alive", nil),
        ("", nil),
    ])
    func eventLines(line: String, expected: String?) {
        #expect(OpenAICompatibleProvider.deltaText(fromEventLine: line) == expected)
    }

    @Test("providers without streaming deliver the whole answer at once")
    func fallback() async throws {
        var pieces: [String] = []
        for try await piece in StubProvider(always: "· 一\n· 二").stream(CompletionRequest(system: "", user: "")) {
            pieces.append(piece)
        }
        #expect(pieces == ["· 一\n· 二"])
    }

    @Test("cleans reasoning preambles from streamed text")
    func cleaning() {
        #expect(Assistant.clean("<think>想一想") == "")
        #expect(Assistant.clean("<think>想</think>\n· 结论 ") == "· 结论")
        #expect(Assistant.clean("  · 结论\n") == "· 结论")
    }
}
