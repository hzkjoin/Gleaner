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
        /// A one-to-one chat, as the app says: written to the user.
        case direct
        /// Not known to be a group or one-to-one chat, and no @mention of the user found.
        case unspecified
    }

    /// Chat apps whose group notifications read "Sender: message" (lowercased).
    static let groupChatApps: Set<String> = [
        "com.tencent.xinwechat", "com.tencent.xin", "com.tencent.weworkmac", "com.tencent.qq",
        "com.alibaba.dingtalkmac", "com.bytedance.macos.feishu", "com.electron.lark",
    ]

    /// What WeChat shows instead of the message when someone @mentions the user in a group:
    /// "张三在群聊中@了你". The "了你" after the @ is not a name.
    static let mentionedYouPhrases = ["@了你", "mentioned you"]

    /// "Sender: message" at the start of the body: a half-width colon followed by a space,
    /// or a full-width colon (which is usually not followed by one).
    static let groupSenderPattern = #"^[^:：\n]{1,32}(: |：)"#

    static let everyoneTokens = ["所有人", "全体成员", "全体", "all", "everyone", "here", "channel"]

    /// `@` not preceded by an email-local-part character, then the name up to a separator.
    static let mentionPattern = #"(?<![A-Za-z0-9._%+\-])[@＠]([^\s@＠,，:：;；!！?？、。]+)"#

    public var userNames: [String]

    public init(userNames: [String]) {
        // Names are sometimes written with the @ in front.
        self.userNames = userNames.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@＠")) }
            .filter { !$0.isEmpty }
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
        let body = notification.body
        if notification.mentionsUser || Self.saysMentionedYou(body) { return .user }
        let group = Self.isGroupMessage(notification)
        let tokens = Self.mentions(in: body)
        let direct = Self.isDirectChat(notification)
        guard !tokens.isEmpty else { return group ? .nobodyInGroup : (direct ? .direct : .unspecified) }

        if tokens.contains(where: isUser) || mentionsUserByName(body) { return .user }
        if tokens.contains(where: { token in Self.everyoneTokens.contains { token.lowercased().hasPrefix($0) } }) {
            return .everyone
        }
        // An @ in a one-to-one chat is still written to the user.
        if direct { return .direct }
        // Without the user's names we cannot tell whether one of the mentions is them.
        return userNames.isEmpty ? .unspecified : .others
    }

    /// One of the user's names (two characters or more) appears, with or without an @.
    public func namesUser(_ body: String) -> Bool {
        let body = body.lowercased()
        return userNames.contains { $0.count >= 2 && body.contains($0.lowercased()) }
    }

    static func saysMentionedYou(_ body: String) -> Bool {
        mentionedYouPhrases.contains { body.localizedCaseInsensitiveContains($0) }
    }

    /// "@" right before one of the user's names (two characters or more), which also catches
    /// names with spaces that the @ pattern cuts short.
    private func mentionsUserByName(_ body: String) -> Bool {
        let body = body.lowercased()
        return userNames.contains { name in
            name.count >= 2 && ["@", "＠"].contains { body.contains($0 + name.lowercased()) }
        }
    }

    /// WeChat chats that aren't people: official accounts ("gh_…") and system senders.
    static let nonPersonChatIDs: Set<String> = ["weixin", "notifymessage", "brandsessionholder", "brandservicesessionholder",
                                                "filehelper", "newsapp", "fmessage", "medianote", "floatbottle", "qqmail"]

    /// A one-to-one chat with a person: as the app says, or else a chat app's message without
    /// the "Sender: message" shape of group messages.
    public static func isDirectChat(_ notification: AppNotification) -> Bool {
        if let chatID = notification.chatID, !chatID.isEmpty {
            return !chatID.hasSuffix("@chatroom") && !chatID.hasPrefix("gh_") && !nonPersonChatIDs.contains(chatID.lowercased())
        }
        return groupChatApps.contains(notification.appID.lowercased()) && !isGroupMessage(notification)
    }

    /// Group chat as the app says, or else judged by the "Sender: message" shape of the body.
    public static func isGroupMessage(_ notification: AppNotification) -> Bool {
        if let group = notification.isGroupChat { return group }
        return groupChatApps.contains(notification.appID.lowercased())
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
