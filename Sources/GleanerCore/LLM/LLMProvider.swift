import Foundation

/// A single-turn completion request.
public struct CompletionRequest: Sendable {
    public var system: String
    public var user: String
    /// JSON Schema (as JSON text) the response must follow. Providers that support
    /// structured outputs enforce it; others rely on the prompt and lenient parsing.
    public var jsonSchema: String?

    public init(system: String, user: String, jsonSchema: String? = nil) {
        self.system = system
        self.user = user
        self.jsonSchema = jsonSchema
    }
}

/// A large language model backend.
///
/// Gleaner ships with `OpenAICompatibleProvider` and `AnthropicProvider`.
/// Conform to this protocol to add another wire protocol.
public protocol LLMProvider: Sendable {
    /// Returns the model's text output for `request`.
    func complete(_ request: CompletionRequest) async throws -> String

    /// Streams the output in pieces as it is generated.
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error>
}

extension LLMProvider {
    /// Providers without streaming deliver the whole output as one piece.
    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await complete(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum LLMError: LocalizedError, Equatable {
    case invalidURL(String)
    case http(status: Int, body: String)
    case refused
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "接口地址无效：\(url)"
        case .http(let status, let body): return "接口返回 \(status)：\(body)"
        case .refused: return "模型拒绝了这次请求"
        case .unexpectedResponse(let text): return "无法解析模型的返回：\(text)"
        }
    }
}
