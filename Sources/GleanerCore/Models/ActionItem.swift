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
             notificationDate, createdAt, snoozedUntil, sourceIDs, attachmentPath
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
