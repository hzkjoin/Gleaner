import GleanerCore
import SwiftUI

/// Several items from the same chat or sender, in one card.
struct GroupedItemsCard: View {
    @EnvironmentObject private var model: AppModel
    let items: [ActionItem]
    @State private var hovering = false

    private var first: ActionItem { items[0] }
    private var conversation: ConversationKey { ConversationKey(appID: first.appID, title: first.sourceTitle) }
    private var replyItem: ActionItem? {
        items.filter { $0.kind.acceptsReply && !$0.suggestedReply.isEmpty }.max { $0.notificationDate < $1.notificationDate }
    }
    private var appName: String { AppDirectory.shared.name(for: first.appID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AppIcon(bundleID: first.appID, size: 15)
                Text(first.sourceTitle.isEmpty ? appName : first.sourceTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                if first.origin == .iPhone {
                    Image(systemName: "iphone").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                if hovering {
                    HStack(spacing: 0) {
                        if model.canSummarize(conversation) {
                            IconButton(symbol: "list.bullet.clipboard", help: "总结") { model.summarize(conversation) }
                        }
                        IconButton(symbol: "sparkles", help: "提问") {
                            // The newest message of the group, with the chat around it.
                            let latest = items.max { $0.notificationDate < $1.notificationDate } ?? first
                            model.startChat(about: model.attachment(for: latest))
                        }
                        IconMenu(symbol: "hand.thumbsdown", help: "不相关") {
                            if !first.sourceTitle.isEmpty {
                                Button("忽略「\(first.sourceTitle)」") { model.markIrrelevant(first, scope: .conversation) }
                            }
                            Button("忽略 \(appName)") { model.markIrrelevant(first, scope: .app) }
                        }
                        IconButton(symbol: "checkmark", help: "全部完成") { items.forEach(model.complete) }
                    }
                    .padding(.vertical, -6)
                } else if let latest = items.map(\.notificationDate).max() {
                    Text(latest.relativeDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(height: 16)

            VStack(alignment: .leading, spacing: 10) {
                let mixed = Set(items.map(\.kind)).count > 1
                ForEach(items) { GroupedItemLine(item: $0, showsKind: mixed) }
            }
            if let replyItem {
                ReplyBox(item: replyItem).padding(.top, 2)
            }
            SummaryBlock(key: conversation)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(hovering ? Theme.cardStrokeHover : Theme.cardStroke, lineWidth: 0.5))
        .onHover { hovering = $0 }
        .clickable { model.open(items.max { $0.notificationDate < $1.notificationDate } ?? first) }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct GroupedItemLine: View {
    @EnvironmentObject private var model: AppModel
    let item: ActionItem
    let showsKind: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleLine
            // The messages behind it, as on a single card.
            let entries = item.sourceEntries(files: model.files(for: item))
            if !entries.isEmpty { SourceList(entries: entries).padding(.leading, 11) }
        }
        .onHover { hovering = $0 }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(item.priority == .high ? Theme.urgent : Theme.textTertiary.opacity(0.5))
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            if showsKind {
                Text(item.kind.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(item.summary)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(4)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !item.due.isEmpty {
                Text(item.due)
                    .font(.system(size: 11))
                    .foregroundStyle(item.priority == .high ? Theme.urgent : Theme.textTertiary)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "checkmark", help: "完成") { model.complete(item) }
                .padding(.vertical, -6)
                .opacity(hovering ? 1 : 0)
        }
    }
}
