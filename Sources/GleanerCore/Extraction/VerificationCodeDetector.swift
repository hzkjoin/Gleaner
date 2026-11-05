import Foundation

/// Rule-based detection of verification codes.
///
/// Codes are time-critical and follow a fixed format, so they should not depend on a
/// model's judgment. `ActionExtractor` merges these results with the model's output.
public enum VerificationCodeDetector {
    static let keywords = ["验证码", "校验码", "动态码", "确认码", "授权码", "登录码", "verification code",
                           "security code", "one-time", "OTP", "code is", "code:"]

    /// A 4–8 character code containing at least one digit, not part of a longer token.
    static let codePattern = #"(?<![A-Za-z0-9])(?=[A-Za-z]*\d)[A-Za-z0-9]{4,8}(?![A-Za-z0-9])"#

    /// Returns the code in `text` when it reads like a verification message.
    /// `flaggedBySystem` skips the keyword check when the OS already marked the text as a passcode.
    public static func code(in text: String, flaggedBySystem: Bool = false) -> String? {
        let lowered = text.lowercased()
        guard flaggedBySystem || keywords.contains(where: { lowered.contains($0.lowercased()) }) else { return nil }

        // Prefer the code closest after a keyword, e.g. "验证码为 482913" rather than a phone number before it.
        for keyword in keywords {
            guard let keywordRange = text.range(of: keyword, options: .caseInsensitive) else { continue }
            let tail = text[keywordRange.upperBound...]
            if let range = tail.range(of: codePattern, options: .regularExpression) { return String(tail[range]) }
        }
        return text.range(of: codePattern, options: .regularExpression).map { String(text[$0]) }
    }

    /// The sender shown in brackets, e.g. "某某云" from "【某某云】您的验证码…".
    static func sender(in text: String) -> String? {
        guard let range = text.range(of: #"[【\[]([^】\]]{1,20})[】\]]"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst().dropLast())
    }

    /// A code item for `note`, or nil when it does not contain a verification code.
    public static func item(for note: AppNotification) -> ActionItem? {
        let text = [note.title, note.subtitle, note.body].joined(separator: " ")
        guard let code = code(in: text, flaggedBySystem: note.isOneTimePasscode) else { return nil }
        let sender = sender(in: text) ?? note.title
        return ActionItem(
            summary: sender.isEmpty ? "验证码 \(code)" : "验证码 \(code)（\(sender)）",
            priority: .high,
            kind: .code,
            appID: note.appID,
            origin: note.origin,
            sourceTitle: note.title,
            sourceExcerpt: note.body,
            notificationDate: note.date,
            sourceIDs: [note.id]
        )
    }

    /// Code items for every notification that contains a verification code.
    public static func items(in notifications: [AppNotification]) -> [ActionItem] {
        notifications.compactMap(item(for:))
    }
}
