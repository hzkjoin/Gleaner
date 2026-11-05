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
    /// Files and messages sent with the question.
    public var attachments: [ChatAttachment]
    /// Material sent ahead of the question (attachment text, new and older messages), kept as sent
    /// so later requests repeat it exactly and hit the provider's prompt cache.
    public var preamble: String

    public init(id: UUID = UUID(), question: String, answer: String = "", searches: [String] = [], date: Date = Date(),
                failed: Bool = false, attachments: [ChatAttachment] = [], preamble: String = "") {
        self.id = id
        self.question = question
        self.answer = answer
        self.searches = searches
        self.date = date
        self.failed = failed
        self.attachments = attachments
        self.preamble = preamble
    }

    private enum CodingKeys: String, CodingKey { case id, question, answer, searches, date, failed, attachments, preamble }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        searches = try c.decodeIfPresent([String].self, forKey: .searches) ?? []
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        preamble = try c.decodeIfPresent(String.self, forKey: .preamble) ?? ""
    }

    /// The user message as sent: the preamble, then the question.
    public var message: String {
        preamble.isEmpty ? question : "\(preamble)\n\n问题：\(question)"
    }
}

/// Something a conversation is about: a received file, or a message and its chat.
public struct ChatAttachment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, message }

    public var kind: Kind
    /// The file name, or the message as shown in the list.
    public var title: String
    public var path: String?
    public var appID: String?
    /// The chat or sender the message came from.
    public var conversation: String?
    /// The original message.
    public var excerpt: String?

    public static func file(path: String) -> ChatAttachment {
        ChatAttachment(kind: .file, title: (path as NSString).lastPathComponent, path: path)
    }

    public static func message(title: String, appID: String, conversation: String, excerpt: String) -> ChatAttachment {
        ChatAttachment(kind: .message, title: title, appID: appID, conversation: conversation, excerpt: excerpt)
    }
}

/// A conversation with the assistant.
public struct ChatSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var turns: [ChatTurn]
    public var createdAt: Date
    public var updatedAt: Date
    /// What the questions are about (sessions from before attachments moved to turns).
    public var attachments: [ChatAttachment]
    /// The system prompt built for the first question and reused for every later one, so the
    /// conversation's prefix stays the same and the provider can serve it from its prompt cache.
    public var context: String?

    public init(id: UUID = UUID(), turns: [ChatTurn] = [], createdAt: Date = Date(), attachments: [ChatAttachment] = []) {
        self.id = id
        self.turns = turns
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case id, turns, createdAt, updatedAt, attachments, context }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        turns = try c.decodeIfPresent([ChatTurn].self, forKey: .turns) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        context = try c.decodeIfPresent(String.self, forKey: .context)
    }

    /// Everything attached so far, oldest first.
    public var allAttachments: [ChatAttachment] { attachments + turns.flatMap(\.attachments) }

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
