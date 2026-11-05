import Foundation

/// One question and its answer.
public struct ChatTurn: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var question: String
    public var answer: String
    /// Web searches made while answering.
    public var searches: [String]
    public var date: Date
    /// The answer could not be produced.
    public var failed: Bool

    public init(id: UUID = UUID(), question: String, answer: String = "", searches: [String] = [], date: Date = Date(),
                failed: Bool = false) {
        self.id = id
        self.question = question
        self.answer = answer
        self.searches = searches
        self.date = date
        self.failed = failed
    }

    private enum CodingKeys: String, CodingKey { case id, question, answer, searches, date, failed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        searches = try c.decodeIfPresent([String].self, forKey: .searches) ?? []
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }
}

/// A conversation with the assistant.
public struct ChatSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var turns: [ChatTurn]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), turns: [ChatTurn] = [], createdAt: Date = Date()) {
        self.id = id
        self.turns = turns
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// The first question, which names the conversation in the list.
    public var title: String {
        turns.first?.question.replacingOccurrences(of: "\n", with: " ") ?? ""
    }
}

extension Array where Element == ChatSession {
    /// Most recent first, without empty sessions, at most `limit`.
    public func trimmedForStorage(limit: Int = 50) -> [ChatSession] {
        Array(filter { !$0.turns.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }
}
