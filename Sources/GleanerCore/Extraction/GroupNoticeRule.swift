import Foundation

/// Group messages that @mention nobody but say something of substance become a "值得关注"
/// notice by rule, so they are not left to the model's judgment. Small talk is skipped.
public enum GroupNoticeRule {
    /// Shorter than this (ignoring sender, emoji and punctuation) counts as small talk.
    static let minimumLength = 6

    static let smallTalk = ["好的", "好", "收到", "哈哈", "哈", "谢谢", "感谢", "嗯", "嗯嗯", "ok", "okay", "明白", "了解",
                            "可以", "行", "对", "是的", "赞", "666", "辛苦了", "辛苦", "+1", "1", "在", "在的", "没问题"]

    /// One notice per group, from messages not already covered by `covered` notification ids.
    public static func items(in batch: [AppNotification], analyzer: MentionAnalyzer,
                             covered: Set<String>) -> [ActionItem] {
        let candidates = batch.filter {
            !covered.contains($0.id) && analyzer.addressee(of: $0) == .nobodyInGroup && isSubstantive($0.body)
        }
        return Dictionary(grouping: candidates) { ConversationKey(appID: $0.appID, title: $0.title) }
            .values
            .compactMap { messages -> ActionItem? in
                let sorted = messages.sorted { $0.date < $1.date }
                guard let latest = sorted.last else { return nil }
                var item = ActionItem(
                    summary: snippet(of: latest.body),
                    priority: .low,
                    kind: .notice,
                    appID: latest.appID,
                    origin: latest.origin,
                    sourceTitle: latest.title,
                    sourceExcerpt: sorted.map(\.body).joined(separator: " / "),
                    notificationDate: latest.date,
                    sourceIDs: sorted.map(\.id)
                )
                item.setSources(sorted)
                return item
            }
            .sorted { $0.notificationDate < $1.notificationDate }
    }

    /// The message without its "Sender: " prefix.
    static func content(of body: String) -> String {
        guard let range = body.range(of: MentionAnalyzer.groupSenderPattern, options: .regularExpression) else { return body }
        return String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    public static func isSubstantive(_ body: String) -> Bool {
        let text = content(of: body).lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol && !$0.isEmoji }
        guard text.count >= minimumLength else { return false }
        // Only small-talk words, e.g. "哈哈哈好的收到".
        var rest = text
        for word in smallTalk.sorted(by: { $0.count > $1.count }) { rest = rest.replacingOccurrences(of: word, with: "") }
        return !rest.isEmpty
    }

    static func snippet(of body: String, limit: Int = 18) -> String {
        let text = content(of: body).replacingOccurrences(of: "\n", with: " ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

private extension Character {
    var isEmoji: Bool {
        unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }
}
