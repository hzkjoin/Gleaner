import Foundation

public enum Priority: String, Codable, CaseIterable, Sendable, Comparable {
    case high, medium, low

    /// Lower rank sorts first.
    public var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rank < rhs.rank }
}

/// What kind of attention an item needs.
public enum ActionKind: String, Codable, CaseIterable, Sendable {
    /// Someone is waiting for the user's reply.
    case reply
    /// Something to do: approve, submit, fill in, attend.
    case task
    /// A one-time verification code.
    case code
    /// An exception or security notice to look into.
    case alert
    /// Worth a look: a group message that addresses no one in particular.
    case notice

    /// Items that come from a person can carry a suggested reply; codes and alerts cannot.
    public var acceptsReply: Bool { self == .reply || self == .task }
}

/// Something the user needs to act on, extracted from one or more notifications.
public struct ActionItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// What the user needs to do, in one short sentence.
    public var summary: String
    /// Free-form deadline such as "今天 18:00"; empty when there is none.
    public var due: String
    public var priority: Priority
    public var kind: ActionKind
    /// A ready-to-send reply in the user's voice, for items that came from a person; otherwise empty.
    public var suggestedReply: String
    /// Bundle identifier of the app the item came from.
    public var appID: String
    /// The device the source notification was delivered on.
    public var origin: DeviceOrigin
    /// Title of the source notification (chat name, sender, ...).
    public var sourceTitle: String
    /// Bodies of the source notifications, joined.
    public var sourceExcerpt: String
    public var notificationDate: Date
    public var createdAt: Date
    /// Hidden from the list until this moment ("稍后提醒").
    public var snoozedUntil: Date?
    /// Ids of the notifications the item was extracted from.
    public var sourceIDs: [String]
    /// A file the item refers to (a received file), opened from the card.
    public var attachmentPath: String?
    /// A calendar event or reminder proposed for the item, until the user adds or dismisses it.
    public var schedule: ScheduleSuggestion?
    /// The source messages one by one, oldest first. Empty for items saved before it existed.
    public var sourceMessages: [String] = []
    /// Received files gathered into this item when items were merged.
    public var sourceFiles: [String] = []

    /// Every received file the item covers: its own and any merged in.
    public var files: [String] {
        var result = attachmentPath.map { [$0] } ?? []
        for path in sourceFiles where !result.contains(path) { result.append(path) }
        return result
    }

    /// File names the messages mention as sent files ("张三: [文件] 报价单.xlsx").
    public var mentionedFiles: [String] {
        messages.compactMap { message in
            let text = Self.stripSender(message)
            guard text.hasPrefix("[文件]") else { return nil }
            let name = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    /// The messages to show as text, leaving out lines that only name a file in `files`,
    /// since those files appear as their own boxes.
    public func textMessages(files: [String]) -> [String] {
        let names = Set(files.map { ($0 as NSString).lastPathComponent })
        guard !names.isEmpty else { return messages }
        return messages.filter { message in
            var text = Self.stripSender(message)
            if text.hasPrefix("[文件]") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            return !names.contains(text)
        }
    }

    public var textMessages: [String] { textMessages(files: files) }

    /// One line of an item's source: a message, or a file shown where it was sent.
    public enum SourceEntry: Hashable, Sendable {
        case text(String)
        /// `sender` is nil for the file source's own line, which has no sender.
        case file(sender: String?, path: String)
    }

    /// The source messages in order, with each of `files` placed where it was sent: at its
    /// "张三: [文件] 名字" message, or at the bare file name line; files mentioned nowhere go last.
    public func sourceEntries(files: [String]) -> [SourceEntry] {
        let byName = Dictionary(files.map { (($0 as NSString).lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        // Names that have a "[文件]" message: their bare name lines are duplicates.
        let sent = Set(messages.compactMap { message -> String? in
            let text = Self.stripSender(message)
            return text.hasPrefix("[文件]") ? text.dropFirst(4).trimmingCharacters(in: .whitespaces) : nil
        })
        var placed = Set<String>()
        var entries: [SourceEntry] = []
        for message in messages {
            let text = Self.stripSender(message)
            if text.hasPrefix("[文件]") {
                let name = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
                if let path = byName[name], !placed.contains(path) {
                    placed.insert(path)
                    entries.append(.file(sender: Self.sender(of: message), path: path))
                    continue
                }
            } else if let path = byName[text] {
                if sent.contains(text) || placed.contains(path) { continue }
                placed.insert(path)
                entries.append(.file(sender: Self.sender(of: message), path: path))
                continue
            }
            entries.append(.text(message))
        }
        for path in files where !placed.contains(path) { entries.append(.file(sender: nil, path: path)) }
        return entries
    }

    /// "张三" from "张三: 内容", or nil when the message has no sender.
    static func sender(of message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }), text.distance(from: text.startIndex, to: colon) <= 20 else {
            return nil
        }
        let sender = text[..<colon].trimmingCharacters(in: .whitespaces)
        return sender.isEmpty ? nil : sender
    }

    /// "张三: 内容" → "内容".
    static func stripSender(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }), text.distance(from: text.startIndex, to: colon) <= 20 {
            return String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// The source messages one by one, oldest first; older items split their joined excerpt.
    public var messages: [String] {
        if !sourceMessages.isEmpty { return sourceMessages }
        return sourceExcerpt.components(separatedBy: " / ").filter { !$0.isEmpty }
    }

    public init(
        id: UUID = UUID(),
        summary: String,
        due: String = "",
        priority: Priority = .medium,
        kind: ActionKind = .task,
        suggestedReply: String = "",
        appID: String,
        origin: DeviceOrigin = .mac,
        sourceTitle: String,
        sourceExcerpt: String,
        notificationDate: Date,
        createdAt: Date = Date(),
        snoozedUntil: Date? = nil,
        sourceIDs: [String] = [],
        attachmentPath: String? = nil
    ) {
        self.id = id
        self.summary = summary
        self.due = due
        self.priority = priority
        self.kind = kind
        self.suggestedReply = suggestedReply
        self.appID = appID
        self.origin = origin
        self.sourceTitle = sourceTitle
        self.sourceExcerpt = sourceExcerpt
        self.notificationDate = notificationDate
        self.createdAt = createdAt
        self.snoozedUntil = snoozedUntil
        self.sourceIDs = sourceIDs
        self.attachmentPath = attachmentPath
    }

    /// The code in a verification-code item, e.g. "482913" from "验证码 482913（某某云）".
    public var verificationCode: String? {
        guard kind == .code else { return nil }
        let pattern = VerificationCodeDetector.codePattern
        if let range = summary.range(of: pattern, options: .regularExpression) { return String(summary[range]) }
        return VerificationCodeDetector.code(in: sourceExcerpt)
    }
}

extension ActionItem {
    private enum CodingKeys: String, CodingKey {
        case id, summary, due, priority, kind, suggestedReply, appID, origin, sourceTitle, sourceExcerpt,
             notificationDate, createdAt, snoozedUntil, sourceIDs, attachmentPath, schedule, sourceMessages, sourceFiles
    }

    /// Decodes items saved by earlier versions, which lacked some of the newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            summary: try c.decode(String.self, forKey: .summary),
            due: try c.decodeIfPresent(String.self, forKey: .due) ?? "",
            priority: try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .medium,
            kind: try c.decodeIfPresent(ActionKind.self, forKey: .kind) ?? .task,
            suggestedReply: try c.decodeIfPresent(String.self, forKey: .suggestedReply) ?? "",
            appID: try c.decode(String.self, forKey: .appID),
            origin: try c.decodeIfPresent(DeviceOrigin.self, forKey: .origin) ?? .mac,
            sourceTitle: try c.decodeIfPresent(String.self, forKey: .sourceTitle) ?? "",
            sourceExcerpt: try c.decodeIfPresent(String.self, forKey: .sourceExcerpt) ?? "",
            notificationDate: try c.decode(Date.self, forKey: .notificationDate),
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            snoozedUntil: try c.decodeIfPresent(Date.self, forKey: .snoozedUntil),
            sourceIDs: try c.decodeIfPresent([String].self, forKey: .sourceIDs) ?? [],
            attachmentPath: try c.decodeIfPresent(String.self, forKey: .attachmentPath)
        )
        schedule = try c.decodeIfPresent(ScheduleSuggestion.self, forKey: .schedule)
        sourceMessages = try c.decodeIfPresent([String].self, forKey: .sourceMessages) ?? []
        sourceFiles = try c.decodeIfPresent([String].self, forKey: .sourceFiles) ?? []
    }
}

extension Array where Element == ActionItem {
    /// Highest priority first, then newest first.
    public func sortedForDisplay() -> [ActionItem] {
        sorted {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.notificationDate > $1.notificationDate
        }
    }
}
