import Foundation

extension Array where Element == ActionItem {
    /// Items from the same chat or sender, in order of first appearance.
    public func groupedByConversation() -> [[ActionItem]] {
        var order: [ConversationKey] = []
        var groups: [ConversationKey: [ActionItem]] = [:]
        for item in self {
            let key = ConversationKey(appID: item.appID, title: item.sourceTitle)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.compactMap { groups[$0] }
    }

    /// One group per conversation, filed under the most pressing kind in it, sections in
    /// `order`. Verification codes always stay on their own.
    public func conversationSections(order: [ActionKind]) -> [(kind: ActionKind, groups: [[ActionItem]])] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let codes = filter { $0.kind == .code }.map { [$0] }
        let conversations = filter { $0.kind != .code }.groupedByConversation()

        var sections: [ActionKind: [[ActionItem]]] = [:]
        for group in codes + conversations {
            let lead = group.map(\.kind).min { (rank[$0] ?? .max) < (rank[$1] ?? .max) } ?? .task
            sections[lead, default: []].append(group)
        }
        return order.compactMap { kind in sections[kind].map { (kind, $0) } }
    }

    /// Adds `new` items, folding each into an open item from the same conversation when it
    /// is the same kind and says nearly the same thing (e.g. a second reminder about the same
    /// request). A conversation keeps a single notice, updated to the latest. Codes are never folded.
    public func merging(_ new: [ActionItem]) -> [ActionItem] {
        var result = self
        for item in new {
            // The same code twice (e.g. through two sources) is one item.
            if let code = item.verificationCode, result.contains(where: { $0.verificationCode == code }) { continue }
            let key = ConversationKey(appID: item.appID, title: item.sourceTitle)
            if item.kind != .code,
               let index = result.firstIndex(where: {
                   $0.kind == item.kind && ConversationKey(appID: $0.appID, title: $0.sourceTitle) == key
                       && (item.kind == .notice
                           || SummarySimilarity.isSimilar($0.summary, item.summary, ignoring: item.sourceTitle))
               }) {
                result[index].absorb(item)
            } else {
                result.append(item)
            }
        }
        return result
    }
}

extension ActionItem {
    /// Takes the newer item's wording, deadline and time, and keeps the more urgent priority.
    mutating func absorb(_ newer: ActionItem) {
        summary = newer.summary
        if !newer.due.isEmpty { due = newer.due }
        priority = Swift.min(priority, newer.priority)
        notificationDate = Swift.max(notificationDate, newer.notificationDate)
        createdAt = newer.createdAt
        snoozedUntil = nil
        let excerpts = [sourceExcerpt, newer.sourceExcerpt].filter { !$0.isEmpty }.joined(separator: " / ")
        sourceExcerpt = String(excerpts.suffix(300))
        sourceMessages = Array((messages + newer.messages.filter { !messages.contains($0) }).suffix(30))
        // Files keep their own boxes after merging.
        sourceFiles = (files + newer.files).reduce(into: [String]()) { result, path in
            if path != attachmentPath && !result.contains(path) { result.append(path) }
        }
        sourceIDs += newer.sourceIDs.filter { !sourceIDs.contains($0) }
    }
}

/// Whether two short summaries say nearly the same thing, by overlap of two-character pieces
/// (Dice coefficient).
public enum SummarySimilarity {
    /// - Parameter ignoring: Text to remove first, typically the conversation name, which
    ///   summaries from one conversation tend to share ("回复王总问题" / "回复王总报价").
    public static func isSimilar(_ a: String, _ b: String, ignoring: String = "", threshold: Double = 0.5) -> Bool {
        let x = normalized(a, ignoring: ignoring), y = normalized(b, ignoring: ignoring)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x.contains(y) || y.contains(x) { return true }
        let gx = bigrams(x), gy = bigrams(y)
        guard !gx.isEmpty, !gy.isEmpty else { return false }
        return 2 * Double(gx.intersection(gy).count) / Double(gx.count + gy.count) >= threshold
    }

    static func normalized(_ text: String, ignoring: String = "") -> [Character] {
        var text = text.lowercased()
        let ignored = ignoring.lowercased().trimmingCharacters(in: .whitespaces)
        if !ignored.isEmpty { text = text.replacingOccurrences(of: ignored, with: "") }
        return Array(text.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
    }

    static func bigrams(_ chars: [Character]) -> Set<String> {
        guard chars.count > 1 else { return Set(chars.map(String.init)) }
        return Set((0..<chars.count - 1).map { String(chars[$0...$0 + 1]) })
    }
}

/// The twice-daily summary notification.
public enum Briefing {
    /// Hours at which a briefing is sent.
    public static let hours = [9, 18]

    /// The most recent briefing time that has passed and has not been sent yet, if any.
    public static func dueSlot(now: Date = Date(), lastSent: Date?, calendar: Calendar = .current) -> Date? {
        let slots = hours.compactMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: now) }
        guard let slot = slots.filter({ $0 <= now }).max() else { return nil }
        // Only within an hour of the slot, so a Mac woken at 15:00 does not send the morning one.
        guard now.timeIntervalSince(slot) < 3600 else { return nil }
        if let lastSent, lastSent >= slot { return nil }
        return slot
    }

    /// "3 件待处理，2 条热点", or nil when there is nothing to report.
    public static func message(actionable: Int, news: Int) -> String? {
        var parts: [String] = []
        if actionable > 0 { parts.append("\(actionable) 件待处理") }
        if news > 0 { parts.append("\(news) 条热点") }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }
}
