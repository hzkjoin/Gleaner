import GleanerCore
import SwiftUI

/// Items that left the list, and what happened to each analyzed notification.
struct HistoryView: View {
    enum Tab { case items, activity }

    @EnvironmentObject private var model: AppModel
    @State private var tab: Tab = .items
    @State private var shownItems = LoadMoreRow.pageSize
    @State private var shownActivity = LoadMoreRow.pageSize

    var body: some View {
        VStack(spacing: 0) {
            header
            SegmentedTabs(selection: $tab, tabs: [
                (.items, "事项", nil),
                (.activity, "记录", nil),
            ])
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.bottom, 10)

            switch tab {
            case .items: itemsList
            case .activity: activityList
            }
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        ZStack {
            Text("历史").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            HStack {
                Button {
                    model.route = .main
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("返回")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                Spacer()
                if canClear {
                    Button("清空") { tab == .items ? model.clearHistory() : model.clearActivity() }
                        .buttonStyle(PillButtonStyle())
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var canClear: Bool {
        tab == .items ? !model.history.isEmpty : !model.activity.isEmpty
    }

    @ViewBuilder
    private var itemsList: some View {
        if model.history.isEmpty {
            empty
        } else {
            card {
                ForEach(Array(model.history.prefix(shownItems).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { divider }
                    HistoryRow(entry: entry)
                }
                if model.history.count > shownItems {
                    Rectangle().fill(Theme.divider).frame(height: 0.5)
                    LoadMoreRow(remaining: model.history.count - shownItems) { shownItems += LoadMoreRow.pageSize }
                }
            }
        }
    }

    @ViewBuilder
    private var activityList: some View {
        if model.activity.isEmpty {
            empty
        } else {
            card {
                ForEach(Array(model.activity.prefix(shownActivity).enumerated()), id: \.element.id) { index, record in
                    if index > 0 { divider }
                    ActivityRow(record: record)
                }
                if model.activity.count > shownActivity {
                    Rectangle().fill(Theme.divider).frame(height: 0.5)
                    LoadMoreRow(remaining: model.activity.count - shownActivity) { shownActivity += LoadMoreRow.pageSize }
                }
            }
        }
    }

    private var empty: some View {
        Text("暂无记录")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }

    private var divider: some View {
        Rectangle().fill(Theme.divider).frame(height: 0.5).padding(.leading, 40)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        AutoSizingScrollView(maxHeight: 520) {
            VStack(spacing: 0, content: content)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: ResolvedItem
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(bundleID: entry.item.appID, size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(label)
                    Text(entry.date.shortTime)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            Button("恢复") { model.restore(entry) }
                .buttonStyle(PillButtonStyle())
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var label: String {
        switch entry.resolution {
        case .done: return "完成"
        case .archived: return "归档"
        case .irrelevant: return "不相关"
        case .scheduled: return "已加日程"
        }
    }
}

/// One analyzed notification: where it came from and what became of it.
private struct ActivityRow: View {
    let record: ActivityRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(bundleID: record.appID, size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.title.isEmpty ? AppDirectory.shared.name(for: record.appID) : record.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(record.date.shortTime)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                if !record.excerpt.isEmpty {
                    Text(record.excerpt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(tag)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(record.isKept ? Theme.onInk : Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(record.isKept ? Theme.ink.opacity(0.85) : Theme.subtleFill))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var tag: String {
        switch record.outcome {
        case .item(let kind, _): return kind.title
        case .news: return "热点"
        case .skipped(let reason):
            switch reason {
            case .notActionable: return "无需处理"
            case .mentionsOthers: return "@他人"
            case .mutedConversation, .ignoredApp: return "已忽略"
            case .empty: return "无内容"
            case .duplicate: return "重复"
            case .rule: return "规则"
            }
        }
    }

    private var detail: String? {
        switch record.outcome {
        case .item(_, let summary): return summary
        case .news(let headline): return headline
        case .skipped: return nil
        }
    }
}

extension Date {
    /// "19:42" today, "昨天 19:42", or "11/3 19:42".
    var shortTime: String {
        let calendar = Calendar.current
        let time = formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDateInToday(self) { return time }
        if calendar.isDateInYesterday(self) { return "昨天 \(time)" }
        return formatted(.dateTime.month(.defaultDigits).day()) + " " + time
    }
}
