import Foundation

/// A function the model may call, described with a JSON Schema.
public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments, as JSON text.
    public var parameters: String

    public init(name: String, description: String, parameters: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A call the model asked for.
public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// The arguments as JSON text, as the model wrote them.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// One string argument, e.g. `query`.
    public func argument(_ key: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return nil }
        return json[key] as? String
    }
}

/// One message of a multi-turn exchange.
public struct ChatMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }

    public var role: Role
    public var content: String
    /// For assistant messages that call tools.
    public var toolCalls: [ToolCall]
    /// For tool results: the call being answered.
    public var toolCallID: String?
    /// Reasoning a thinking model produced alongside tool calls; some vendors require it back.
    public var reasoning: String?

    public init(role: Role, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil, reasoning: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoning = reasoning
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: text) }
}

/// Prompt tokens of one request, and how many were served from the provider's cache.
public struct PromptUsage: Sendable, Equatable {
    public var promptTokens: Int
    public var cachedTokens: Int

    public init(promptTokens: Int, cachedTokens: Int) {
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
    }
}

public enum ChatStreamEvent: Sendable {
    case text(String)
    /// Reported at the end of the reply, when the provider includes it.
    case usage(PromptUsage)
    /// Sent once at the end of a reply that calls tools, with the reasoning that came with it.
    case toolCalls([ToolCall], reasoning: String?)
}

/// A provider that can hold a multi-turn exchange and call tools.
public protocol ToolCallingProvider: LLMProvider {
    /// Streams one reply. With `allowTools` false the model must answer in text even when
    /// `tools` are listed (they are kept so earlier tool calls in `messages` stay valid).
    func streamChat(_ messages: [ChatMessage], tools: [ToolSpec], allowTools: Bool) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

/// Assembles text and tool calls from a chat-completions event stream, where tool calls
/// arrive in fragments keyed by index.
struct ChatStreamParser {
    private var calls: [Int: ToolCall] = [:]
    private(set) var reasoning = ""
    private(set) var usage: PromptUsage?

    var toolCalls: [ToolCall] {
        calls.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty }
    }

    /// Consumes one `data: {...}` line and returns any text in it.
    mutating func consume(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let usage = json["usage"] as? [String: Any], let prompt = usage["prompt_tokens"] as? Int {
            // DeepSeek reports `prompt_cache_hit_tokens`; OpenAI and others `prompt_tokens_details.cached_tokens`.
            let cached = usage["prompt_cache_hit_tokens"] as? Int
                ?? (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            self.usage = PromptUsage(promptTokens: prompt, cachedTokens: cached)
        }
        guard let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { return nil }
        if let thinking = delta["reasoning_content"] as? String { reasoning += thinking }
        for fragment in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
            let index = fragment["index"] as? Int ?? 0
            var call = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
            if let id = fragment["id"] as? String, !id.isEmpty { call.id = id }
            if let function = fragment["function"] as? [String: Any] {
                if let name = function["name"] as? String { call.name += name }
                if let arguments = function["arguments"] as? String { call.arguments += arguments }
            }
            calls[index] = call
        }
        guard let content = delta["content"] as? String, !content.isEmpty else { return nil }
        return content
    }
}
