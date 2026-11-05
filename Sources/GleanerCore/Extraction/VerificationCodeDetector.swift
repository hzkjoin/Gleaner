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

    /// How far after a keyword the code may be. Long texts (emails) mention "OTP" in footers far
    /// from any number that belongs to it.
    static let maxDistance = 80

    /// Returns the code in `text` when it reads like a verification message: one that follows a
    /// keyword closely. `flaggedBySystem` (the OS marked the text as a passcode) allows a code
    /// without a keyword.
    public static func code(in text: String, flaggedBySystem: Bool = false) -> String? {
        for keyword in keywords {
            for keywordRange in occurrences(of: keyword, in: text) {
                let tail = text[keywordRange.upperBound...].prefix(maxDistance)
                if let range = tail.range(of: codePattern, options: .regularExpression) { return String(tail[range]) }
            }
        }
        guard flaggedBySystem else { return nil }
        return text.range(of: codePattern, options: .regularExpression).map { String(text[$0]) }
    }

    /// Where `keyword` appears; English keywords only as whole words ("OTP", not "hotpot").
    static func occurrences(of keyword: String, in text: String) -> [Range<String.Index>] {
        let isEnglish = keyword.unicodeScalars.allSatisfy(\.isASCII)
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        let pattern = isEnglish ? "(?<![A-Za-z])\(escaped)(?![A-Za-z])" : escaped
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// The sender shown in brackets, e.g. "某某云" from "【某某云】您的验证码…".
    static func sender(in text: String) -> String? {
        guard let range = text.range(of: #"[【\[]([^】\]]{1,20})[】\]]"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst().dropLast())
    }

    /// Longer texts are left to the model, which reads the whole thing.
    static let maxRuleLength = 300

    /// Whether the rule decides for this notification: texts flagged by the system as passcodes,
    /// and short messages. Mail and long texts mention codes and security notices in ways a rule
    /// misreads (a statement's footer about OTPs), so the model decides those, a few seconds later.
    public static func appliesByRule(to note: AppNotification) -> Bool {
        if note.isOneTimePasscode { return true }
        guard note.appID.lowercased() != MailSource.appID else { return false }
        return [note.title, note.subtitle, note.body].joined(separator: " ").count <= maxRuleLength
    }

    /// A code item for `note`, or nil when it does not contain a verification code (or is left to the model).
    public static func item(for note: AppNotification) -> ActionItem? {
        guard appliesByRule(to: note) else { return nil }
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
