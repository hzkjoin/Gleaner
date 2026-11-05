import GleanerCore
import SwiftUI

/// News and trending topics, as a compact list in one card.
struct NewsListView: View {
    let news: [NewsItem]
    @State private var shown = LoadMoreRow.pageSize

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(news.prefix(shown).enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(Theme.divider).frame(height: 0.5).padding(.leading, 42)
                }
                NewsRow(item: item)
            }
            if news.count > shown {
                Rectangle().fill(Theme.divider).frame(height: 0.5)
                LoadMoreRow(remaining: news.count - shown) { shown += LoadMoreRow.pageSize }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }
}

private struct NewsRow: View {
    @EnvironmentObject private var model: AppModel
    let item: NewsItem
    @State private var hovering = false

    private var appName: String { AppDirectory.shared.name(for: item.appID) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(bundleID: item.appID, size: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.headline)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(item.category.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.subtleFill))
                    HStack(spacing: 6) {
                        Text(appName)
                        Text(item.date.relativeDescription)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    if item.origin == .iPhone {
                        Image(systemName: "iphone")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 4)
            IconButton(symbol: "xmark", help: "移除") { model.dismiss(item) }
                .padding(.top, -4)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onHover { hovering = $0 }
        .background(hovering ? Theme.subtleFill.opacity(0.5) : .clear)
        .clickable { AppDirectory.shared.open(item.appID) }
        .hoverHint(item.sourceExcerpt, followsPointer: true)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
