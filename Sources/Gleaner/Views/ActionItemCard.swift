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
            } else {
                // Messages in order, each file where it was sent; a reply item's message is its title.
                let entries = item.datedSourceEntries(files: model.files(for: item)).filter { dated in
                    if case .text = dated.entry { return !showsMessageAsTitle }
                    return true
                }
                if !entries.isEmpty { SourceList(entries: entries) }
            }
            if !item.schedules.isEmpty {
                ScheduleList(item: item).padding(.top, 2)
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
        .clickable { model.open(item) }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// The chat the item came from; for a received file, the chat that sent it when known.
    private var sourceName: String {
        if item.sourceTitle.isEmpty, let path = item.attachmentPath, let origin = model.origin(ofFile: path) {
            return origin.conversation
        }
        return item.sourceTitle.isEmpty ? appName : item.sourceTitle
    }

    private var sourceLine: some View {
        HStack(spacing: 6) {
            AppIcon(bundleID: item.appID, size: 15)
            Text(sourceName)
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
                        IconButton(symbol: "list.bullet.clipboard", help: "总结") { model.summarize(conversation) }
                    }
                    if item.kind != .code {
                        IconButton(symbol: "sparkles", help: "提问") { model.startChat(about: model.attachment(for: item)) }
                    }
                    if item.kind != .code && item.schedules.isEmpty {
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
/// The source messages one per line, newest last, with received files in place. Long runs
/// show the latest two, with the earlier ones a click away.
/// An item's messages, oldest first, with files where they were sent.
struct SourceList: View {
    @EnvironmentObject private var model: AppModel
    let entries: [ActionItem.DatedEntry]
    @State private var expanded = false

    /// Shown while collapsed: the newest ones, which the summary is usually about.
    private let collapsedCount = 2

    var body: some View {
        let hidden = max(entries.count - collapsedCount, 0)
        let shown = expanded ? entries : Array(entries.suffix(collapsedCount))
        let hasText = entries.contains { if case .text = $0.entry { return true } else { return false } }
        let timed = showsTimes
        HStack(alignment: .top, spacing: 8) {
            // A file on its own needs no quote bar.
            if hasText { RoundedRectangle(cornerRadius: 1).fill(Theme.divider).frame(width: 2) }
            VStack(alignment: .leading, spacing: 5) {
                if hidden > 0 {
                    Button(expanded ? "收起" : "展开 \(hidden) 条") {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, dated in
                    switch dated.entry {
                    case .text(let message):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Self.line(message)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .lineSpacing(2)
                                .lineLimit(expanded ? 8 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                            if timed, let date = dated.date {
                                Spacer(minLength: 0)
                                Text(Self.time(date))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .fixedSize()
                            }
                        }
                    case .file(let sender, let path):
                        VStack(alignment: .leading, spacing: 4) {
                            if let sender = sender ?? model.origin(ofFile: path)?.sender {
                                Text(sender + "：")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            FileBox(path: path)
                            FileSummaryBlock(path: path)
                        }
                    }
                }
            }
        }
    }

    /// Times only when the messages are spread out; a burst reads as one moment.
    private var showsTimes: Bool {
        let dates = entries.compactMap(\.date)
        guard dates.count >= 2, let first = dates.min(), let last = dates.max() else { return false }
        return last.timeIntervalSince(first) >= 120
    }

    /// "14:05", "昨天 14:05", "11月3日 14:05".
    static func time(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        formatter.dateFormat = calendar.isDateInYesterday(date) ? "'昨天' HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// "张三: 内容" with the sender set apart.
    static func line(_ message: String) -> Text {
        let text = message.replacingOccurrences(of: "\n", with: " ")
        if let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let sender = text[..<colon]
            if !sender.isEmpty, sender.count <= 20, !sender.contains("http") {
                return Text(sender + "：").fontWeight(.medium).foregroundColor(Theme.textPrimary)
                    + Text(text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return Text(text)
    }
}

/// A received file, with open.
/// A received file; clicking the row opens it.
private struct FileBox: View {
    @EnvironmentObject private var model: AppModel
    let path: String
    @State private var hovering = false

    private var readable: Bool { FileTextExtractor.canExtract(URL(fileURLWithPath: path)) }

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
            HStack(spacing: 0) {
                if readable {
                    IconButton(symbol: "list.bullet.clipboard", help: "总结") { model.summarizeFile(path) }
                    IconButton(symbol: "sparkles", help: "提问") { model.startChat(about: .file(path: path)) }
                }
                IconButton(symbol: "folder", help: "在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    PanelDismissal.dismiss()
                }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous).fill(Theme.inset))
        .onHover { hovering = $0 }
        .clickable { open() }
    }

    private func open() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(URL(fileURLWithPath: path), configuration: configuration)
        PanelDismissal.dismiss()
    }
}

/// Key points of a received file, shown under it once asked for.
private struct FileSummaryBlock: View {
    @EnvironmentObject private var model: AppModel
    let path: String

    var body: some View {
        if let state = model.fileSummaries[path] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("文件要点").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    IconButton(symbol: "xmark", help: "收起") { model.dismissFileSummary(path) }
                        .padding(.vertical, -6)
                }
                StreamingResult(state: state)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous).fill(Theme.inset))
        }
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

/// A proposed calendar event or reminder: what, when and where, added once the user confirms.
/// The item's proposed events or reminders, each on its own; with several, one button adds all.
private struct ScheduleList: View {
    @EnvironmentObject private var model: AppModel
    let item: ActionItem
    @State private var addingAll = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(item.schedules, id: \.self) { ScheduleBox(item: item, suggestion: $0) }
            if item.schedules.count > 1 {
                HStack(spacing: 8) {
                    if failed {
                        Text("没有日历或提醒事项的权限").font(.system(size: 11.5)).foregroundStyle(Theme.caution)
                    }
                    Button(item.schedules.allSatisfy { $0.kind == .event } ? "全部加到日历" : "全部添加") {
                        addingAll = true
                        failed = false
                        Task {
                            failed = !(await model.addAllSchedules(for: item))
                            addingAll = false
                        }
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(addingAll)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

private struct ScheduleBox: View {
    @EnvironmentObject private var model: AppModel
    let item: ActionItem
    let suggestion: ScheduleSuggestion
    @State private var editing = false
    @State private var draft: ScheduleSuggestion
    @State private var adding = false
    @State private var failed = false

    init(item: ActionItem, suggestion: ScheduleSuggestion) {
        self.item = item
        self.suggestion = suggestion
        _draft = State(initialValue: suggestion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing { editor } else { preview }
            if failed {
                Text("没有日历或提醒事项的权限").font(.system(size: 11.5)).foregroundStyle(Theme.caution)
            }
            HStack(spacing: 6) {
                Spacer()
                if editing {
                    Button("取消") {
                        draft = suggestion
                        editing = false
                    }
                    .buttonStyle(PillButtonStyle())
                } else {
                    Button("修改") { editing = true }
                        .buttonStyle(PillButtonStyle())
                }
                Button(draft.kind == .event ? "加到日历" : "加到提醒事项", action: add)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(adding || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous).fill(Theme.inset))
        // Clicks here belong to the box, not to the card (which opens the app).
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var preview: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: draft.kind == .event ? "calendar" : "checklist")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(Self.when(draft))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                if !draft.location.isEmpty {
                    Text(draft.location)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            IconButton(symbol: "xmark", help: "不用") { model.dismissSchedule(suggestion, of: item) }
                .padding(.vertical, -6)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $draft.kind) {
                Text("日历").tag(ScheduleSuggestion.Kind.event)
                Text("提醒事项").tag(ScheduleSuggestion.Kind.reminder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField("标题", text: $draft.title)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                DatePicker("", selection: $draft.start,
                           displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                if draft.kind == .event && !draft.allDay {
                    Text("至").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    DatePicker("", selection: Binding(get: { draft.effectiveEnd }, set: { draft.end = $0 }),
                               displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                }
                Toggle("全天", isOn: $draft.allDay)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            if draft.kind == .event {
                TextField("地点", text: $draft.location)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .font(.system(size: 12.5))
    }

    private func add() {
        adding = true
        failed = false
        var confirmed = draft
        confirmed.title = confirmed.title.trimmingCharacters(in: .whitespaces)
        Task {
            let saved = await model.addSchedule(for: item, suggestion, as: confirmed)
            adding = false
            failed = !saved
        }
    }

    /// "11月6日 周五 15:00–16:30", "11月6日 周五 全天", "截止 11月20日 周五".
    static func when(_ suggestion: ScheduleSuggestion) -> String {
        let chinese = Locale(identifier: "zh_CN")
        func day(_ date: Date) -> String {
            let calendar = Calendar.current
            let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(chinese))
            if calendar.isDateInToday(date) { return "今天 \(weekday)" }
            if calendar.isDateInTomorrow(date) { return "明天 \(weekday)" }
            return "\(date.formatted(.dateTime.month().day().locale(chinese))) \(weekday)"
        }
        let time = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        switch suggestion.kind {
        case .event:
            if suggestion.allDay { return "\(day(suggestion.start)) 全天" }
            return "\(day(suggestion.start)) \(suggestion.start.formatted(time))–\(suggestion.effectiveEnd.formatted(time))"
        case .reminder:
            return "截止 \(day(suggestion.start))" + (suggestion.allDay ? "" : " \(suggestion.start.formatted(time))")
        }
    }
}
