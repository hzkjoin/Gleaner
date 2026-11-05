import GleanerCore
import SwiftUI

/// Conversations with the assistant: the current one, or the list of earlier ones.
struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingList = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if showingList {
                ChatList { id in
                    model.openChat(id)
                    showingList = false
                }
            } else {
                ChatThread()
            }
        }
        .frame(height: 560)
        .background(Theme.canvas)
    }

    private var header: some View {
        ZStack {
            Text(showingList ? "历史会话" : "提问")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 0) {
                Button {
                    if showingList { showingList = false } else { model.route = .main }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("返回")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                Spacer()
                if !showingList {
                    IconButton(symbol: "clock", help: "历史会话") { showingList = true }
                        .disabled(model.chats.isEmpty)
                        .opacity(model.chats.isEmpty ? 0.4 : 1)
                    IconButton(symbol: "square.and.pencil", help: "新会话") { model.currentChatID = nil }
                        .disabled(model.currentChatID == nil)
                        .opacity(model.currentChatID == nil ? 0.4 : 1)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.leading, Theme.horizontalPadding)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// The current conversation, with the input at the bottom.
private struct ChatThread: View {
    @EnvironmentObject private var model: AppModel
    @State private var question = ""
    @FocusState private var focused: Bool
    @State private var pasteMonitor: Any?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(model.currentChat?.turns ?? []) { turn in
                            TurnView(turn: turn, answering: model.answeringTurnID == turn.id)
                                .id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.currentChat?.turns.last) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if model.currentChat == nil {
                    Text("问问拾穗")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            input
        }
        .onAppear {
            focused = true
            // ⌘V with files or an image on the clipboard attaches them; text pastes as usual.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v",
                      MainActor.assumeIsolated({ pasteAttachments() }) else { return event }
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.attach(files: [url]) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.currentChatID) { _, _ in focused = true }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.currentAttachments, id: \.self) { attachment in
                AttachmentChip(attachment: attachment) { model.removeAttachment(attachment) }
            }
            field
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(Theme.cardStroke, lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// Attaches files or an image from the clipboard; false when it holds neither (plain text).
    private func pasteAttachments() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            model.attach(files: urls)
            return true
        }
        guard board.string(forType: .string) == nil,
              let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        model.attach(image: png)
        return true
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Above the menu bar panel, which floats at status bar level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        NSApp.activate()
        PanelDismissal.isPickingFiles = true
        panel.begin { response in
            if response == .OK { model.attach(files: panel.urls) }
            // Hand focus back to the menu bar panel, which macOS would otherwise give to the
            // previous app (and the panel would close).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                PanelDismissal.isPickingFiles = false
                PanelDismissal.refocus?()
            }
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            IconButton(symbol: "paperclip", help: "添加文件", action: chooseFiles)
                .padding(.leading, -6)
                .padding(.bottom, -1)
            TextField("", text: $question, prompt: Text(model.currentChat == nil ? "问点什么" : "继续问"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 3)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.onInk)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(canSend ? Theme.ink : Theme.textTertiary.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.answeringTurnID == nil
    }

    private func send() {
        guard canSend else { return }
        model.ask(question)
        question = ""
    }
}

/// A question on the right, its answer below on the left.
private struct TurnView: View {
    let turn: ChatTurn
    let answering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turn.attachments.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(turn.attachments, id: \.self) { attachment in
                            SentAttachment(attachment: attachment)
                        }
                    }
                }
            }
            HStack {
                Spacer(minLength: 48)
                Text(turn.question)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.onInk)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink))
            }
            if !turn.searches.isEmpty {
                // One quiet line, however many searches were made.
                Label(turn.searches.joined(separator: "、"), systemImage: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 2)
            }
            Group {
                if !turn.answer.isEmpty {
                    BulletText(text: turn.answer, size: 13, lineSpacing: 4, paragraphSpacing: 9)
                } else if answering {
                    ProgressView().controlSize(.small)
                } else if turn.failed {
                    Text("没有结果").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
            .padding(.trailing, 24)
        }
    }
}

/// Earlier conversations, most recent first.
private struct ChatList: View {
    @EnvironmentObject private var model: AppModel
    let open: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.chats) { chat in
                    ChatRow(chat: chat, current: chat.id == model.currentChatID) { open(chat.id) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if model.chats.isEmpty {
                Text("暂无会话").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct ChatRow: View {
    @EnvironmentObject private var model: AppModel
    let chat: ChatSession
    let current: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.system(size: 13, weight: current ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(chat.updatedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "trash", help: "删除") { model.deleteChat(chat.id) }
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous)
            .fill(hovering ? Theme.subtleFill : .clear))
        .onHover { hovering = $0 }
        .clickable(action: open)
    }
}

/// A file or message waiting to be sent, with a way to drop it.
private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let remove: () -> Void

    static func label(for attachment: ChatAttachment) -> String {
        guard attachment.kind == .message, let conversation = attachment.conversation, !conversation.isEmpty else {
            return attachment.title
        }
        return "\(conversation)：\(attachment.excerpt ?? attachment.title)"
    }

    var body: some View {
        HStack(spacing: 6) {
            AttachmentIcon(attachment: attachment)
            Text(Self.label(for: attachment))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            IconButton(symbol: "xmark", help: "去掉", action: remove)
                .padding(.vertical, -6)
        }
        .padding(.leading, 7)
        .padding(.trailing, 1)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.inset))
    }
}

/// An attachment sent with a question: images as thumbnails, other files and messages as labels.
/// Clicking a file opens it.
private struct SentAttachment: View {
    let attachment: ChatAttachment

    private var image: NSImage? {
        guard attachment.kind == .file, let path = attachment.path,
              FileTextExtractor.images.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 180, maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
            } else {
                HStack(spacing: 6) {
                    AttachmentIcon(attachment: attachment)
                    Text(AttachmentChip.label(for: attachment))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
            }
        }
        .clickable {
            guard attachment.kind == .file, let path = attachment.path else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            PanelDismissal.dismiss()
        }
    }
}

private struct AttachmentIcon: View {
    let attachment: ChatAttachment

    var body: some View {
        if attachment.kind == .file, let path = attachment.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
        } else {
            AppIcon(bundleID: attachment.appID ?? "", size: 14)
        }
    }
}
