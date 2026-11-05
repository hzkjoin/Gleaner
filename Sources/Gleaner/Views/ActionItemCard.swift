import GleanerCore
import SwiftUI

/// One action item: source line, summary, deadline, and a kind-specific body
/// (verification code or the original message).
struct ActionItemCard: View {
    @EnvironmentObject private var model: AppModel
    let item: ActionItem
    @State private var hovering = false

    private var appName: String { AppDirectory.shared.name(for: item.appID) }
    private var conversation: ConversationKey { ConversationKey(appID: item.appID, title: item.sourceTitle) }
    /// A message waiting for a reply is clearer as itself than as a summary of it.
    private var showsMessageAsTitle: Bool { item.kind == .reply && !item.sourceExcerpt.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            sourceLine
            summary
            if !item.due.isEmpty { dueLine }

            if let code = item.verificationCode {
                CodeBox(code: code) { model.complete(item) }
                    .padding(.top, 2)
            } else if let path = item.attachmentPath {
                FileBox(path: path)
                    .padding(.top, 2)
            } else if !item.sourceExcerpt.isEmpty && !showsMessageAsTitle {
                QuoteText(text: item.sourceExcerpt)
            }
            if item.kind.acceptsReply && !item.suggestedReply.isEmpty {
                ReplyBox(item: item).padding(.top, 2)
            }
            SummaryBlock(key: conversation)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(hovering ? Theme.cardStrokeHover : Theme.cardStroke, lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .clickable { AppDirectory.shared.open(item.appID) }
        .hoverHint(AppDirectory.shared.isIPhoneApp(item.appID) ? "iPhone 镜像" : "打开\(appName)", followsPointer: true)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var sourceLine: some View {
        HStack(spacing: 6) {
            AppIcon(bundleID: item.appID, size: 15)
            Text(item.sourceTitle.isEmpty ? appName : item.sourceTitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if item.origin == .iPhone {
                Image(systemName: "iphone")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .hoverHint("iPhone")
            }
            Spacer(minLength: 8)
            if hovering {
                HStack(spacing: 0) {
                    if item.kind != .code && model.canSummarize(conversation) {
                        IconButton(symbol: "text.alignleft", help: "总结") { model.summarize(conversation) }
                    }
                    if item.kind != .code {
                        IconMenu(symbol: "calendar.badge.plus", help: "加到日程") {
                            let due = model.due(of: item)
                            Button(due.map { "提醒事项（\(Self.describe($0))）" } ?? "提醒事项") {
                                Task { await model.schedule(item, as: .reminder) }
                            }
                            if let due {
                                Button("日历（\(Self.describe(due))）") { Task { await model.schedule(item, as: .event) } }
                            }
                        }
                    }
                    IconMenu(symbol: "clock", help: "稍后提醒") {
                        ForEach(SnoozeOption.allCases) { option in
                            if let date = option.date() {
                                Button(option.title) { model.snooze(item, until: date) }
                            }
                        }
                    }
                    IconMenu(symbol: "hand.thumbsdown", help: "不相关") {
                        if !item.sourceTitle.isEmpty {
                            Button("忽略「\(item.sourceTitle)」") { model.markIrrelevant(item, scope: .conversation) }
                        }
                        Button("忽略 \(appName)") { model.markIrrelevant(item, scope: .app) }
                        Divider()
                        Button("仅此一条") { model.markIrrelevant(item, scope: .once) }
                    }
                    IconButton(symbol: "checkmark", help: "完成") { model.complete(item) }
                }
                .padding(.vertical, -6)
                .transition(.opacity)
            } else {
                Text(item.notificationDate.relativeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(height: 16)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if item.priority == .high && item.kind != .code {
                Circle()
                    .fill(Theme.urgent)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            }
            Text(showsMessageAsTitle ? item.sourceExcerpt : item.summary)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dueLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock").font(.system(size: 10.5))
            Text(item.due)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(item.priority == .high ? Theme.urgent : Theme.textSecondary)
    }
}

// MARK: - Parts

extension ActionItemCard {
    /// "今天 15:00", "明天", "11月8日 10:00".
    static func describe(_ due: DueDateParser.Due) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(due.date) { day = "今天" }
        else if calendar.isDateInTomorrow(due.date) { day = "明天" }
        else { day = due.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()) }
        guard due.hasTime else { return day }
        return day + " " + due.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

struct AppIcon: View {
    let bundleID: String
    var size: CGFloat

    var body: some View {
        Group {
            if let icon = AppDirectory.shared.icon(for: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The original message, quoted with a thin bar.
private struct QuoteText: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.divider).frame(width: 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A received file, with open.
/// A received file; clicking the row opens it.
private struct FileBox: View {
    let path: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 22, height: 22)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            IconButton(symbol: "folder", help: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                PanelDismissal.dismiss()
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous).fill(Theme.inset))
        .onHover { hovering = $0 }
        .clickable { open() }
        .hoverHint("打开文件")
    }

    private func open() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(URL(fileURLWithPath: path), configuration: configuration)
        PanelDismissal.dismiss()
    }
}

/// A verification code shown large, with copy.
private struct CodeBox: View {
    let code: String
    let onDone: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(code)
                .font(.system(size: 21, weight: .semibold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Spacer()
            Button(copied ? "已复制" : "复制") {
                Clipboard.copy(code)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            Button("完成", action: onDone).buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous).fill(Theme.inset))
    }
}
