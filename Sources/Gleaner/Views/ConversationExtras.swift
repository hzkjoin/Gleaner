import GleanerCore
import SwiftUI

/// An editable suggested reply with copy and copy-and-open.
struct ReplyBox: View {
    @EnvironmentObject private var model: AppModel
    let item: ActionItem
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...5)
                .onChange(of: draft) { _, text in model.updateReply(for: item.id, to: text) }
            HStack {
                Spacer()
                Button("复制并打开") { copyAndOpen() }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous).fill(Theme.inset))
        .onAppear { draft = item.suggestedReply }
    }

    /// Copies the reply and brings the app forward, ready to paste. For WeChat, opens the chat
    /// and pastes the reply into it, unsent.
    private func copyAndOpen() {
        Clipboard.copy(draft)
        PanelDismissal.dismiss()
        if let chat = model.weChatChat(for: item) {
            let reply = draft
            Task { await WeChatLocator.open(conversation: chat, reply: reply) }
        } else if let url = model.messageURL(for: item) {
            // Messages opens on the conversation, ready to paste.
            NSWorkspace.shared.open(url)
        } else {
            AppDirectory.shared.open(item.appID)
        }
    }
}

/// Model output as rows: lines starting with "-" (or "•", "·") become bulleted rows, other lines plain paragraphs.
struct BulletText: View {
    let text: String
    var size: CGFloat = 12.5
    var lineSpacing: CGFloat = 2
    var paragraphSpacing: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: paragraphSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("·") || line.hasPrefix("-") || line.hasPrefix("•") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.textTertiary).frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3.5 }
                        styled(String(line.drop { "·-• ".contains($0) }))
                    }
                } else {
                    styled(line)
                }
            }
        }
        .font(.system(size: size))
        .foregroundStyle(Theme.textPrimary)
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Inline Markdown (bold, code) for the content; sources in smaller, lighter type.
    private func styled(_ line: String) -> Text {
        AnswerText.segments(line).reduce(Text("")) { result, segment in
            if segment.isSource {
                return result + Text(segment.text).font(.system(size: size - 1.5)).foregroundColor(Theme.textTertiary)
            }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let content = (try? AttributedString(markdown: segment.text, options: options)) ?? AttributedString(segment.text)
            return result + Text(content)
        }
    }
}

/// Text that is still arriving, or a spinner before the first piece.
struct StreamingResult: View {
    let state: AppModel.SummaryState

    var body: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
        case .text(let text, _):
            BulletText(text: text)
        case .failed:
            Text("没有结果").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// A conversation summary shown inside its card.
struct SummaryBlock: View {
    @EnvironmentObject private var model: AppModel
    let key: ConversationKey

    var body: some View {
        if let state = model.summaries[key] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("摘要").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    IconButton(symbol: "xmark", help: "收起") { model.dismissSummary(key) }
                        .padding(.vertical, -6)
                }
                StreamingResult(state: state)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous).fill(Theme.inset))
        }
    }
}

