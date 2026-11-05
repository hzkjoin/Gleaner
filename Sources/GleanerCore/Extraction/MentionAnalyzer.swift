import Foundation

/// Decides who a notification is addressed to, from @mentions in its text.
///
/// Done in code rather than by the model because the rule is exact: a group message
/// that @mentions specific people, none of them the user, is not the user's business.
public struct MentionAnalyzer: Sendable {
    public enum Addressee: Equatable, Sendable {
        /// @mentions the user.
        case user
        /// @mentions everyone (@所有人, @all).
        case everyone
        /// @mentions specific people, none of them the user.
        case others
        /// A group chat message that @mentions nobody: at most worth a look.
        case nobodyInGroup
        /// No @mentions outside a group chat, or the user's names are unknown.
        case unspecified
    }

    /// Chat apps whose group notifications read "Sender: message".
    static let groupChatApps: Set<String> = [
        "com.tencent.xinwechat", "com.tencent.weworkmac", "com.tencent.qq",
        "com.alibaba.DingTalkMac", "com.bytedance.macos.feishu", "com.electron.lark",
    ]

    /// "Sender: message" at the start of the body: a half-width colon followed by a space,
    /// or a full-width colon (which is usually not followed by one).
    static let groupSenderPattern = #"^[^:：\n]{1,32}(: |：)"#

    static let everyoneTokens = ["所有人", "全体成员", "全体", "all", "everyone", "here", "channel"]

    /// `@` not preceded by an email-local-part character, then the name up to a separator.
    static let mentionPattern = #"(?<![A-Za-z0-9._%+\-])@([^\s@,，:：;；!！?？、。]+)"#

    public var userNames: [String]

    public init(userNames: [String]) {
        self.userNames = userNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Names that follow an @ in `text`.
    public static func mentions(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: mentionPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    public func addressee(of notification: AppNotification) -> Addressee {
        if notification.mentionsUser { return .user }
        let tokens = Self.mentions(in: notification.body)
        guard !tokens.isEmpty else { return Self.isGroupMessage(notification) ? .nobodyInGroup : .unspecified }

        if tokens.contains(where: isUser) { return .user }
        if tokens.contains(where: { token in Self.everyoneTokens.contains { token.lowercased().hasPrefix($0) } }) {
            return .everyone
        }
        // Without the user's names we cannot tell whether one of the mentions is them.
        return userNames.isEmpty ? .unspecified : .others
    }

    public static func isGroupMessage(_ notification: AppNotification) -> Bool {
        groupChatApps.contains(notification.appID)
            && notification.body.range(of: groupSenderPattern, options: .regularExpression) != nil
    }

    /// Exact match, or containment for names of two or more characters so that a group
    /// nickname like "K（霍振坤）" still matches "霍振坤". A one-letter name such as "K" must
    /// match exactly, otherwise it would match "@Alex".
    private func isUser(_ token: String) -> Bool {
        let token = token.lowercased()
        return userNames.contains { name in
            let name = name.lowercased()
            return token == name || (name.count >= 2 && token.contains(name))
        }
    }
}
