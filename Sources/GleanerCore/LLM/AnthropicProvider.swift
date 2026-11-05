import Foundation

/// Anthropic Messages protocol (`POST {base}/v1/messages`).
///
/// Against the official API (`api.anthropic.com`) it also uses structured outputs,
/// a low effort level, and server-side refusal fallbacks. Third-party endpoints that
/// speak the same protocol get a plain request, since they may not support those extras.
public struct AnthropicProvider: LLMProvider {
    public static let officialHost = "api.anthropic.com"
    static let officialAPIVersion = "2026-10-21"
    /// Widely accepted by Anthropic-compatible third-party endpoints.
    static let compatibleAPIVersion = "2023-06-01"
    /// Models that accept `fallbacks: "default"`.
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var maxTokens: Int
    /// Lets the model use the server-side web search tool (official API only).
    public var webSearch: Bool
    public var http: HTTPClient

    /// Models that take the web search version with dynamic filtering; others get the basic one.
    static let dynamicSearchModels: Set<String> = [
        "claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
        "claude-opus-4-6", "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-6",
    ]
    /// Resends after `pause_turn` (the server's search loop hit its limit) at most this often.
    static let maxContinuations = 3

    public init(baseURL: String, model: String, apiKey: String, maxTokens: Int = 8000, webSearch: Bool = false,
                http: HTTPClient = URLSessionHTTPClient()) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.webSearch = webSearch
        self.http = http
    }

    var isOfficial: Bool { URL(string: baseURL)?.host == Self.officialHost }

    func requestBody(for request: CompletionRequest) -> (headers: [String: String], body: [String: Any]) {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
        ]
        var headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": isOfficial ? Self.officialAPIVersion : Self.compatibleAPIVersion,
        ]

        if isOfficial {
            // The system prompt is the stable part (instructions, a conversation's context); mark it
            // for caching so repeated requests read it from the cache.
            body["system"] = [["type": "text", "text": request.system, "cache_control": ["type": "ephemeral"]]]
            // Classification is simple; low effort keeps latency and cost down.
            var outputConfig: [String: Any] = ["effort": "low"]
            if let schemaText = request.jsonSchema, let schema = HTTPSupport.jsonObject(schemaText) {
                outputConfig["format"] = ["type": "json_schema", "schema": schema]
            }
            body["output_config"] = outputConfig

            if webSearch {
                let type = Self.dynamicSearchModels.contains(model) ? "web_search_20260209" : "web_search_20250305"
                body["tools"] = [["type": type, "name": "web_search", "max_uses": 3]]
            }

            if Self.fallbackModels.contains(model) {
                // If a safety classifier declines, the API retries on a suitable model server-side.
                body["fallbacks"] = "default"
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            }
        }
        return (headers, body)
    }

    public func complete(_ request: CompletionRequest) async throws -> String {
        let url = try HTTPSupport.endpoint(base: baseURL, path: "/v1/messages")
        var (headers, body) = requestBody(for: request)
        var continuations = 0
        while true {
            let response = try await http.post(url, headers: headers, body: JSONSerialization.data(withJSONObject: body))
            guard response.status == 200 else {
                throw LLMError.http(status: response.status, body: HTTPSupport.snippet(response.body))
            }
            guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw LLMError.unexpectedResponse(HTTPSupport.snippet(response.body))
            }
            let stopReason = json["stop_reason"] as? String
            if stopReason == "refusal" { throw LLMError.refused }
            let content = json["content"] as? [[String: Any]] ?? []

            if stopReason == "pause_turn", continuations < Self.maxContinuations {
                // The server's search loop paused; send the turn back so it resumes where it left off.
                continuations += 1
                body["messages"] = [["role": "user", "content": request.user], ["role": "assistant", "content": content]]
                continue
            }
            let text = Self.answerText(from: content)
            guard !text.isEmpty else { throw LLMError.unexpectedResponse(HTTPSupport.snippet(response.body)) }
            return text
        }
    }

    /// The text after the last web search result, so remarks made before searching are left out.
    static func answerText(from content: [[String: Any]]) -> String {
        let lastSearch = content.lastIndex { ($0["type"] as? String)?.hasSuffix("_tool_result") == true }
        let answer = lastSearch.map { Array(content[content.index(after: $0)...]) } ?? content
        return answer.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }
}
