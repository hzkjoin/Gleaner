import GleanerCore
import SwiftUI

/// The window that drops down from the menu bar item.
struct PanelView: View {
    enum Tab { case items, news }

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updater = Updater.shared
    @State private var tab: Tab = .items

    var body: some View {
        Group {
            switch model.route {
            case .settings:
                SettingsView()
            case .history:
                HistoryView()
            case .ask:
                ChatView()
            case .main:
                VStack(spacing: 0) {
                    header
                    if let version = updater.availableVersion {
                        UpdateBanner(version: version) { updater.checkForUpdates() }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                    if showsTabs {
                        HStack {
                            SegmentedTabs(selection: $tab, tabs: [
                                (.items, "待处理", model.actionableItems.count),
                                (.news, "热点", model.news.count),
                            ])
                            Spacer()
                            if tab == .items && model.canShowOverview && model.overview == nil {
                                OverviewButton { model.showOverview() }
                            }
                            if tab == .news && !model.news.isEmpty {
                                Button("清空") { model.clearNews() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(.horizontal, Theme.horizontalPadding)
                        .padding(.bottom, 10)
                    }
                    content
                        .padding(.bottom, 4)
                }
            }
        }
        .frame(width: Theme.panelWidth)
        .hintLayer()
        // Opaque canvas: keeps text crisp instead of blending with the wallpaper.
        .background(Theme.canvas)
        // If the window is ever taller than the content, keep the content under the menu bar
        // rather than centered.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("拾穗")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            StatusPill(status: model.status, focusMode: model.focusMode) { model.checkNow() }
            AskButton { model.startNewChat() }
            HStack(spacing: 0) {
                IconButton(symbol: "arrow.clockwise", help: "立即检查") { model.checkNow() }
                IconButton(symbol: "clock.arrow.circlepath", help: "历史") { model.route = .history }
                IconButton(symbol: "gearshape", help: "设置") { model.route = .settings }
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        Date().formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.wide))
    }

    private var showsTabs: Bool {
        model.status != .accessDenied && (model.settings.collectNews || !model.news.isEmpty)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if showsTabs && tab == .news {
            newsContent
        } else {
            itemsContent
        }
    }

    @ViewBuilder
    private var newsContent: some View {
        if model.news.isEmpty {
            EmptyState(symbol: "newspaper", title: "暂无热点", message: nil)
        } else {
            AutoSizingScrollView(maxHeight: 540) {
                NewsListView(news: model.news)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder
    private var itemsContent: some View {
        if let suggestion = model.ruleSuggestion {
            RuleSuggestionCard(rule: suggestion.rule)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        if model.needsModelSetup && model.status != .accessDenied {
            ModelSetupCard()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        if model.status == .accessDenied {
            PermissionCard()
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 14)
        } else if model.visibleItems.isEmpty && model.upcomingEvents.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "一切就绪",
                       message: model.snoozedCount > 0 ? "\(model.snoozedCount) 件稍后提醒" : nil)
        } else {
            if !showsTabs && model.canShowOverview && model.overview == nil {
                HStack {
                    Spacer()
                    OverviewButton { model.showOverview() }
                }
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.bottom, 10)
            }
            AutoSizingScrollView(maxHeight: 540) {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 18) {
                        if let overview = model.overview {
                            OverviewCard(state: overview).id("overview")
                        }
                        if !model.upcomingEvents.isEmpty {
                            EventsCard(events: model.upcomingEvents, now: model.now)
                        }
                        ForEach(model.sections, id: \.kind) { section in
                            SectionView(kind: section.kind, groups: section.groups)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
                    .onChange(of: model.overview == nil) { _, closed in
                        if !closed { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("overview", anchor: .top) } }
                    }
                    .onChange(of: model.revealRequest) { _, request in
                        guard let request else { return }
                        // Cards are anchored by the first item of their group.
                        let group = model.sections.flatMap(\.groups).first { $0.contains { $0.id == request.target } }
                        guard let anchor = group?.first?.id else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .top) }
                    }
                }
            }
        }
    }

}

// MARK: - Pieces

private struct SectionView: View {
    @EnvironmentObject private var model: AppModel
    let kind: ActionKind
    let groups: [[ActionItem]]
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.system(size: 10, weight: .semibold))
                Text(kind.title).font(.system(size: 11.5, weight: .semibold))
                Text("\(groups.reduce(0) { $0 + $1.count })")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                // Completes this section only; shown on hover so it isn't hit by accident.
                Button("全部完成") { groups.joined().forEach(model.complete) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 4)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }

            ForEach(groups, id: \.first?.id) { group in
                Group {
                    if group.count > 1 {
                        GroupedItemsCard(items: group)
                    } else if let item = group.first {
                        ActionItemCard(item: item)
                    }
                }
                .id(group.first?.id)
                .overlay {
                    // Pointed at from the overview.
                    if group.contains(where: { model.highlightedItemIDs.contains($0.id) }) {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(Theme.textPrimary.opacity(0.45), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: model.highlightedItemIDs)
            }
        }
    }
}

/// Current pipeline state. Errors stay here, quietly, instead of taking over the panel;
/// hovering shows the details and clicking retries.
private struct StatusPill: View {
    let status: AppModel.Status
    let focusMode: String?
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            HStack(spacing: 5) {
                if case .analyzing = status {
                    ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 8, height: 8)
                } else if status == .idle, focusMode != nil {
                    Image(systemName: "moon.fill").font(.system(size: 8.5))
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.subtleFill))
        }
        .buttonStyle(.plain)
        .hoverHint(help)
    }

    private var label: String {
        switch status {
        case .idle: return focusMode ?? "留意中"
        case .analyzing(let count): return "分析 \(count) 条"
        case .accessDenied: return "需要授权"
        case .failed: return "重试中"
        }
    }

    private var color: Color {
        switch status {
        case .idle, .analyzing: return Theme.positive
        case .accessDenied, .failed: return Theme.caution
        }
    }

    private var help: String {
        switch status {
        case .idle: return "点击立即检查"
        case .analyzing: return "分析中"
        case .accessDenied: return "需要完全磁盘访问权限"
        case .failed(let message): return "\(message)，点击重试"
        }
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 30)
    }
}

private struct PermissionCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.subtleFill))
            VStack(alignment: .leading, spacing: 3) {
                Text("需要完全磁盘访问权限")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("用于读取通知，仅在本机处理")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("授权") { model.startAuthorizationGuide() }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

/// Shown until a model is usable: new installs start with no key.
private struct ModelSetupCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("设置模型", systemImage: "cpu")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("选一个预设，填上 API Key")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Button("去设置") { model.route = .settings }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

/// A rule drawn from items marked irrelevant, offered once.
private struct RuleSuggestionCard: View {
    @EnvironmentObject private var model: AppModel
    let rule: UserRule

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(rule.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Button("设为规则") { model.acceptRuleSuggestion() }
                .buttonStyle(PillButtonStyle(prominent: true))
            IconButton(symbol: "xmark", help: "不用") { model.dismissRuleSuggestion() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

/// Opens the question page; labeled, so it reads as an entry point rather than an icon.
private struct AskButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold))
                Text("提问")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.ink.opacity(hovering ? 0.8 : 1)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A newer version is out: a plain line with a clear button.
private struct UpdateBanner: View {
    let version: String
    let update: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
            Text("检测到新版本 v\(version)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 4)
            Button("立即更新", action: update)
                .buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}
