import Foundation
@testable import GleanerCore

/// Records requests and replays canned responses in order.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    struct Request {
        let url: URL
        let headers: [String: String]
        let body: [String: Any]
    }

    private let lock = NSLock()
    private var responses: [(Int, String)]
    private(set) var requests: [Request] = []

    init(responses: [(status: Int, body: String)]) {
        self.responses = responses.map { ($0.status, $0.body) }
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> (status: Int, body: Data) {
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        return lock.withLock {
            requests.append(Request(url: url, headers: headers, body: json))
            guard !responses.isEmpty else { return (500, Data("no canned response".utf8)) }
            let (status, text) = responses.removeFirst()
            return (status, Data(text.utf8))
        }
    }
}

/// Returns a fixed string, or throws, and counts calls.
final class StubProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Result<String, Error>]
    private(set) var receivedRequests: [CompletionRequest] = []

    init(_ outputs: [Result<String, Error>]) {
        self.outputs = outputs
    }

    convenience init(always output: String, times: Int = 20) {
        self.init(Array(repeating: .success(output), count: times))
    }

    func complete(_ request: CompletionRequest) async throws -> String {
        let next: Result<String, Error> = lock.withLock {
            receivedRequests.append(request)
            return outputs.isEmpty ? .success(#"{"actions":[]}"#) : outputs.removeFirst()
        }
        return try next.get()
    }
}

/// An in-memory notification source.
final class FakeSource: NotificationSource, @unchecked Sendable {
    private let lock = NSLock()
    private var notifications: [AppNotification] = []
    private var token = Date(timeIntervalSince1970: 0)

    func add(_ new: [AppNotification]) {
        lock.lock()
        defer { lock.unlock() }
        notifications.append(contentsOf: new)
        token = token.addingTimeInterval(1)
    }

    func changeToken() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func fetch(after date: Date) throws -> [AppNotification] {
        lock.lock()
        defer { lock.unlock() }
        return notifications.filter { $0.date > date }.sorted { $0.date < $1.date }
    }
}

struct DeniedSource: NotificationSource {
    func changeToken() -> Date? { nil }
    func fetch(after date: Date) throws -> [AppNotification] { throw NotificationSourceError.accessDenied }
}

struct TestError: Error {}

func note(_ id: String, app: String = "com.example.chat", title: String = "群聊", body: String, at date: Date) -> AppNotification {
    AppNotification(id: id, appID: app, title: title, body: body, date: date)
}

func actionsJSON(_ actions: [(sources: [Int], summary: String)]) -> String {
    let items = actions.map { a in
        #"{"sources":[\#(a.sources.map(String.init).joined(separator: ","))],"summary":"\#(a.summary)","due":"","priority":"high"}"#
    }
    return #"{"actions":[\#(items.joined(separator: ","))]}"#
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gleaner-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
