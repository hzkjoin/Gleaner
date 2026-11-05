import Foundation

/// One web search result.
public struct WebResult: Sendable, Hashable, Codable {
    public var title: String
    public var url: String
    public var site: String?
    /// Publication time as the service reports it (RFC 3339), if known.
    public var date: String?
    /// A few hundred characters meant for a model.
    public var summary: String

    public init(title: String, url: String, site: String? = nil, date: String? = nil, summary: String) {
        self.title = title
        self.url = url
        self.site = site
        self.date = date
        self.summary = summary
    }
}

/// Searches the web. Implement this to add another search backend.
public protocol WebSearchService: Sendable {
    /// `question` is the user's original question, which some services use to rank results.
    func search(_ query: String, question: String) async throws -> [WebResult]
}

/// DeepSeek's Search API (`POST https://api.deepseek.com/v1/tools/search`), billed per successful
/// request and authorized with the same key as the model.
public struct DeepSeekWebSearch: WebSearchService {
    public static let host = "api.deepseek.com"

    public var apiKey: String
    public var count: Int
    public var http: HTTPClient

    public init(apiKey: String, count: Int = 5, http: HTTPClient = URLSessionHTTPClient(timeout: 20)) {
        self.apiKey = apiKey
        self.count = count
        self.http = http
    }

    public func search(_ query: String, question: String) async throws -> [WebResult] {
        let url = URL(string: "https://\(Self.host)/v1/tools/search")!
        var body: [String: Any] = ["query": String(query.prefix(128)), "count": count]
        let original = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !original.isEmpty { body["ori_question"] = String(original.prefix(128)) }
        let response = try await http.post(url, headers: ["Content-Type": "application/json", "Authorization": "Bearer \(apiKey)"],
                                           body: JSONSerialization.data(withJSONObject: body))
        guard response.status == 200 else {
            throw LLMError.http(status: response.status, body: HTTPSupport.snippet(response.body))
        }
        return try Self.results(from: response.body)
    }

    static func results(from data: Data) throws -> [WebResult] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw LLMError.unexpectedResponse(HTTPSupport.snippet(data))
        }
        return results.compactMap { item in
            guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
            let summary = (item["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item["snippet"] as? String ?? ""
            return WebResult(title: title, url: url, site: item["site_name"] as? String, date: item["date"] as? String,
                             summary: summary)
        }
    }
}

/// Baidu Search on Qianfan (`POST https://qianfan.baidubce.com/v2/ai_search/web_search`),
/// authorized with a Qianfan API key.
public struct BaiduWebSearch: WebSearchService {
    public static let host = "qianfan.baidubce.com"
    /// The query limit, counting a Chinese character as two.
    static let queryLimit = 72

    public var apiKey: String
    public var count: Int
    public var http: HTTPClient

    public init(apiKey: String, count: Int = 5, http: HTTPClient = URLSessionHTTPClient(timeout: 20)) {
        self.apiKey = apiKey
        self.count = count
        self.http = http
    }

    public func search(_ query: String, question: String) async throws -> [WebResult] {
        let url = URL(string: "https://\(Self.host)/v2/ai_search/web_search")!
        let body: [String: Any] = [
            "messages": [["role": "user", "content": Self.truncated(query)]],
            "search_source": "baidu_search_v2",
            "resource_type_filter": [["type": "web", "top_k": count]],
        ]
        let response = try await http.post(url, headers: ["Content-Type": "application/json", "Authorization": "Bearer \(apiKey)"],
                                           body: JSONSerialization.data(withJSONObject: body))
        return try Self.results(from: response.body, status: response.status)
    }

    static func results(from data: Data, status: Int) throws -> [WebResult] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let json, json["code"] != nil {
            // Errors come back as {"code": ..., "message": ...}, sometimes with HTTP 200.
            throw LLMError.http(status: status, body: json["message"] as? String ?? HTTPSupport.snippet(data))
        }
        guard status == 200, let references = json?["references"] as? [[String: Any]] else {
            throw status == 200 ? LLMError.unexpectedResponse(HTTPSupport.snippet(data))
                                : LLMError.http(status: status, body: HTTPSupport.snippet(data))
        }
        return references.compactMap { item in
            guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
            let content = (item["content"] as? String).map { String($0.prefix(600)) } ?? ""
            let summary = content.isEmpty ? item["snippet"] as? String ?? "" : content
            return WebResult(title: title, url: url, site: item["website"] as? String, date: item["date"] as? String,
                             summary: summary)
        }
    }

    /// Cuts `query` to the limit, counting non-ASCII characters as two.
    static func truncated(_ query: String) -> String {
        var units = 0
        var result = ""
        for character in query {
            units += character.isASCII ? 1 : 2
            guard units <= queryLimit else { break }
            result.append(character)
        }
        return result
    }
}

/// A web search service the user can choose.
public enum WebSearchChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepseek
    case baidu

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .baidu: return "百度"
        }
    }

    /// Keychain account of the channel's key, kept apart from model keys.
    public var secretAccount: String {
        switch self {
        case .deepseek: return "search:\(DeepSeekWebSearch.host)"
        case .baidu: return "search:\(BaiduWebSearch.host)"
        }
    }

    public func makeService(apiKey: String) -> WebSearchService {
        switch self {
        case .deepseek: return DeepSeekWebSearch(apiKey: apiKey)
        case .baidu: return BaiduWebSearch(apiKey: apiKey)
        }
    }
}

extension ProviderConfiguration {
    /// Whether the model can call tools, which searching needs.
    public var supportsToolCalls: Bool { apiProtocol == .openAICompatible }

    /// Whether the model's own key also works for `channel` (the model is that vendor's own API).
    public func sharesKey(with channel: WebSearchChannel) -> Bool {
        supportsToolCalls && channel == .deepseek && secretAccount == DeepSeekWebSearch.host
    }

    /// The key `channel` will use: its own key if set, otherwise the model's key when it works there.
    public func searchKey(for channel: WebSearchChannel, channelKey: String, modelKey: String) -> String {
        let own = channelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? (sharesKey(with: channel) ? modelKey : "") : own
    }

    /// The search service to offer the model, or nil when the model cannot call tools or no key works.
    public func makeWebSearch(channel: WebSearchChannel, channelKey: String, modelKey: String) -> WebSearchService? {
        guard supportsToolCalls else { return nil }
        let key = searchKey(for: channel, channelKey: channelKey, modelKey: modelKey)
        return key.isEmpty ? nil : channel.makeService(apiKey: key)
    }
}
