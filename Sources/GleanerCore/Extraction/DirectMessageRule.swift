import Foundation

/// Every message in a one-to-one chat is shown, whatever the model made of it: messages the
/// model passed over join that person's item if there is one, or become a "值得关注" notice.
public enum DirectMessageRule {
    public static func apply(to items: [ActionItem], batch: [AppNotification], analyzer: MentionAnalyzer,
                             covered: Set<String>) -> [ActionItem] {
        let missed = batch.filter { !covered.contains($0.id) && analyzer.addressee(of: $0) == .direct }
        var result = items
        let chats = Dictionary(grouping: missed) { ConversationKey(appID: $0.appID, title: $0.title) }
        for (key, messages) in chats.sorted(by: { ($0.value.map(\.date).max() ?? .distantPast) < ($1.value.map(\.date).max() ?? .distantPast) }) {
            let sorted = messages.sorted { $0.date < $1.date }
            guard let latest = sorted.last else { continue }
            if let index = result.firstIndex(where: {
                $0.kind != .code && $0.appID.lowercased() == key.appID.lowercased() && $0.sourceTitle == key.title
            }) {
                // Shown with what the model already made of this chat.
                var item = result[index]
                let known = item.sourceIDs
                let added = sorted.filter { !known.contains($0.id) }
                item.sourceIDs += added.map(\.id)
                item.sourceMessages = Array((item.messages + added.map(\.body)).suffix(30))
                if latest.date > item.notificationDate { item.notificationDate = latest.date }
                result[index] = item
                continue
            }
            var item = ActionItem(
                summary: GroupNoticeRule.snippet(of: latest.body),
                priority: .low,
                kind: .notice,
                appID: latest.appID,
                origin: latest.origin,
                sourceTitle: latest.title,
                sourceExcerpt: sorted.map(\.body).joined(separator: " / "),
                notificationDate: latest.date,
                sourceIDs: sorted.map(\.id)
            )
            item.sourceMessages = sorted.map(\.body)
            result.append(item)
        }
        return result
    }
}
