import Foundation

/// OpenAI Chat Completions protocol (`POST {base}/chat/completions`).
///
/// Works with OpenAI, DeepSeek, Qwen (DashScope), Moonshot, Zhipu, a local Ollama, and
/// most other vendors that advertise "OpenAI compatible" endpoints.
public struct OpenAICompatibleProvider: ToolCallingProvider {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    /// When false and the server is local, asks hybrid reasoning models (Qwen3 on Ollama) to
    /// answer without thinking via `reasoning_effort: "none"`. Cloud vendors pick reasoning by
    /// model name, so the field is not sent to them.
    public var reasoning: Bool
    /// Asks vendors with built-in search (Qwen on Model Studio) to search the web when needed.
    public var webSearch: Bool
    public var http: HTTPClient

    public init(baseURL: String, model: String, apiKey: String, reasoning: Bool = true, webSearch: Bool = false,
                http: HTTPClient = URLSessionHTTPClient()) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.reasoning = reasoning
        self.webSearch = webSearch
        self.http = http
    }

    public func complete(_ request: CompletionRequest) async throws -> String {
        let url = try HTTPSupport.endpoint(base: baseURL, path: "/chat/completions")
        var body = requestBody(request, url: url)
        let headers = requestHeaders

        var response = try await http.post(url, headers: headers, body: JSONSerialization.data(withJSONObject: body))
        // Some vendors reject optional parameters. Drop them one at a time, keeping JSON mode longest.
        for key in ["reasoning_effort", "response_format"] where response.status == 400 && body[key] != nil {
            body.removeValue(forKey: key)
            response = try await http.post(url, headers: headers, body: JSONSerialization.data(withJSONObject: body))
        }
        if (500...599).contains(response.status) {
            // Local servers occasionally abort a generation (e.g. a repetition guard); try once more.
            response = try await http.post(url, headers: headers, body: JSONSerialization.data(withJSONObject: body))
        }
        guard response.status == 200 else {
            throw LLMError.http(status: response.status, body: HTTPSupport.snippet(response.body))
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.unexpectedResponse(HTTPSupport.snippet(response.body))
        }
        return content
    }

    /// Server-sent events from `stream: true`. Structured (JSON) requests are not streamed.
    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        guard request.jsonSchema == nil else {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do { continuation.yield(try await complete(request)); continuation.finish() }
                    catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try HTTPSupport.endpoint(base: baseURL, path: "/chat/completions")
                    var body = requestBody(request, url: url)
                    body["stream"] = true
                    var urlRequest = URLRequest(url: url, timeoutInterval: 180)
                    urlRequest.httpMethod = "POST"
                    requestHeaders.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var text = ""
                        for try await line in bytes.lines where text.count < 300 { text += line }
                        throw LLMError.http(status: status, body: String(text.prefix(300)))
                    }
                    for try await line in bytes.lines {
                        if line.hasPrefix("data:"), line.contains("[DONE]") { break }
                        if let piece = Self.deltaText(fromEventLine: line) { continuation.yield(piece) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams a multi-turn exchange, collecting tool calls the model makes.
    public func streamChat(_ messages: [ChatMessage], tools: [ToolSpec], allowTools: Bool) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try HTTPSupport.endpoint(base: baseURL, path: "/chat/completions")
                    var body: [String: Any] = ["model": model, "stream": true, "messages": messages.map(Self.encode)]
                    if !tools.isEmpty {
                        body["tools"] = tools.map(Self.encode)
                        if !allowTools { body["tool_choice"] = "none" }
                    }
                    if !reasoning && ProviderConfiguration.isLocalHost(url.host) { body["reasoning_effort"] = "none" }
                    if webSearch { body["enable_search"] = true }
                    var urlRequest = URLRequest(url: url, timeoutInterval: 180)
                    urlRequest.httpMethod = "POST"
                    requestHeaders.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var text = ""
                        for try await line in bytes.lines where text.count < 300 { text += line }
                        throw LLMError.http(status: status, body: String(text.prefix(300)))
                    }
                    var parser = ChatStreamParser()
                    for try await line in bytes.lines {
                        if line.hasPrefix("data:"), line.contains("[DONE]") { break }
                        if let piece = parser.consume(line) { continuation.yield(.text(piece)) }
                    }
                    let calls = parser.toolCalls
                    if !calls.isEmpty {
                        continuation.yield(.toolCalls(calls, reasoning: parser.reasoning.isEmpty ? nil : parser.reasoning))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func encode(_ message: ChatMessage) -> [String: Any] {
        var json: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if !message.toolCalls.isEmpty {
            json["tool_calls"] = message.toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
            }
        }
        if let id = message.toolCallID { json["tool_call_id"] = id }
        if let reasoning = message.reasoning { json["reasoning_content"] = reasoning }
        return json
    }

    static func encode(_ tool: ToolSpec) -> [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parameters.utf8))) ?? [String: Any]()
        return ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": parameters]]
    }

    /// The text in one `data: {...}` line of a chat-completions stream, if any.
    static func deltaText(fromEventLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return nil }
        return content
    }

    private var requestHeaders: [String: String] {
        var headers = ["Content-Type": "application/json"]
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        return headers
    }

    private func requestBody(_ request: CompletionRequest, url: URL) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
        ]
        if request.jsonSchema != nil {
            // `json_object` is far more widely supported than `json_schema` across vendors.
            body["response_format"] = ["type": "json_object"]
        }
        if !reasoning && ProviderConfiguration.isLocalHost(url.host) {
            // Ollama maps this to "thinking off". (Qwen3's `/no_think` prompt switch no longer works there.)
            body["reasoning_effort"] = "none"
        }
        if webSearch { body["enable_search"] = true }
        return body
    }

}
