import Foundation

/// Minimal HTTP abstraction so providers can be tested without the network.
public protocol HTTPClient: Sendable {
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data)
}

public struct URLSessionHTTPClient: HTTPClient {
    public var timeout: TimeInterval

    /// Local models can take a while to load on the first request, hence the generous default.
    public init(timeout: TimeInterval = 180) {
        self.timeout = timeout
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

enum HTTPSupport {
    /// Joins a user-supplied base URL with an API path.
    ///
    /// Accepts a bare host (`https://api.anthropic.com`), a versioned base
    /// (`https://api.deepseek.com/v1`) or the full endpoint, with or without a trailing slash.
    static func endpoint(base: String, path: String) throws -> URL {
        var url = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }

        if !url.hasSuffix(path) {
            // Avoid ".../v1/v1/messages" when the base already ends with the version segment.
            if let first = path.split(separator: "/").first, path.hasPrefix("/\(first)/"),
               url.hasSuffix("/\(first)") {
                url += String(path.dropFirst(first.count + 1))
            } else {
                url += path
            }
        }
        guard let result = URL(string: url), result.scheme != nil, result.host != nil else {
            throw LLMError.invalidURL(base)
        }
        return result
    }

    static func snippet(_ data: Data, limit: Int = 300) -> String {
        String((String(data: data, encoding: .utf8) ?? "<binary>").prefix(limit))
    }

    static func jsonObject(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}
