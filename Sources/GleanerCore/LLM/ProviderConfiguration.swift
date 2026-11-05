import Foundation

/// Wire protocols Gleaner can speak.
public enum APIProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAICompatible = "openai"
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        }
    }
}

/// User-editable model settings. The API key is kept separately in a `SecretStore`.
public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public var apiProtocol: APIProtocol
    public var baseURL: String
    public var model: String
    /// Let the model think before answering. More accurate, slower. OpenAI-compatible endpoints only;
    /// Anthropic models always use adaptive thinking at low effort.
    public var reasoning: Bool

    public init(apiProtocol: APIProtocol, baseURL: String, model: String, reasoning: Bool = true) {
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.model = model
        self.reasoning = reasoning
    }

    private enum CodingKeys: String, CodingKey { case apiProtocol, baseURL, model, reasoning }

    /// Tolerates configurations saved before `reasoning` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            apiProtocol: try c.decode(APIProtocol.self, forKey: .apiProtocol),
            baseURL: try c.decode(String.self, forKey: .baseURL),
            model: try c.decode(String.self, forKey: .model),
            reasoning: try c.decodeIfPresent(Bool.self, forKey: .reasoning) ?? true
        )
    }

    /// Secret-store account for this endpoint's API key. Keys are stored per host so that
    /// switching between vendors does not overwrite them.
    public var secretAccount: String {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL
    }

    /// True when requests stay on this Mac.
    public var isLocal: Bool {
        Self.isLocalHost(URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host)
    }

    static func isLocalHost(_ host: String?) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host ?? "")
    }

    /// `webSearch` turns on the model's own web search where it has one (see `hasNativeWebSearch`).
    public func makeProvider(apiKey: String, webSearch: Bool = false, http: HTTPClient = URLSessionHTTPClient()) -> LLMProvider {
        let native = webSearch && hasNativeWebSearch
        switch apiProtocol {
        case .openAICompatible:
            return OpenAICompatibleProvider(baseURL: baseURL, model: model, apiKey: apiKey, reasoning: reasoning,
                                            webSearch: native, http: http)
        case .anthropic:
            return AnthropicProvider(baseURL: baseURL, model: model, apiKey: apiKey, webSearch: native, http: http)
        }
    }

    /// Whether the vendor can search the web by itself: Anthropic's API (server-side web search
    /// tool) and Alibaba Cloud Model Studio's Qwen (`enable_search`).
    public var hasNativeWebSearch: Bool {
        let host = secretAccount.lowercased()
        switch apiProtocol {
        case .anthropic: return host == AnthropicProvider.officialHost
        case .openAICompatible: return host == "dashscope.aliyuncs.com" || host.hasSuffix(".maas.aliyuncs.com")
        }
    }
}

/// A named starting point shown in settings.
public struct ProviderPreset: Identifiable, Sendable {
    public let name: String
    public let configuration: ProviderConfiguration
    public var id: String { name }

    public static let all: [ProviderPreset] = [
        .init(name: "本地 Ollama",
              configuration: .init(apiProtocol: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:30b-a3b",
                                   reasoning: false)),
        .init(name: "Claude",
              configuration: .init(apiProtocol: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5")),
        .init(name: "DeepSeek",
              configuration: .init(apiProtocol: .openAICompatible, baseURL: "https://api.deepseek.com", model: "deepseek-flash")),
        .init(name: "通义千问",
              configuration: .init(apiProtocol: .openAICompatible,
                                   baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus")),
    ]

    public static let `default` = all[0]
}
