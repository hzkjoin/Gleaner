import AppKit
import SwiftUI

/// Content of the floating guide: the app icon to drag, and where to drag it.
struct AuthorizationGuideView: View {
    @ObservedObject var guide: AuthorizationGuide
    @State private var nudge = false

    private let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var body: some View {
        HStack(spacing: 12) {
            AppIconDragSource(icon: appIcon)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1.5)
                .hoverHint("拖动")

            VStack(alignment: .leading, spacing: 3) {
                if guide.granted {
                    Label("授权成功", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.positive)
                } else {
                    HStack(alignment: .center, spacing: 5) {
                        Text(instruction)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let arrow {
                            // Centered on the text, nudging a little each way toward the list.
                            Image(systemName: arrow)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 12, height: 12)
                                .offset(x: guide.placement == .beside ? (nudge ? -1.5 : 1.5) : 0,
                                        y: guide.placement == .below ? (nudge ? -1.5 : 1.5) : 0)
                                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: nudge)
                        }
                    }
                    Text("拖不动时，点列表下方的 +，选择「拾穗」")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 10) {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        Button("重新打开系统设置") { NSWorkspace.shared.open(AuthorizationGuide.settingsURL) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 34)
        .padding(.vertical, 12)
        .hintLayer()
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button { guide.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.subtleFill))
            }
            .buttonStyle(.plain)
            .padding(8)
            .hoverHint("关闭")
        }
        .fixedSize()
        .onAppear { nudge = true }
        .animation(.easeOut(duration: 0.25), value: guide.granted)
    }

    private var instruction: String {
        switch guide.placement {
        case .below: return "把图标拖到上方的列表中"
        case .beside: return "把图标拖到左侧的列表中"
        case .unknown: return "把图标拖到系统设置的列表中"
        }
    }

    private var arrow: String? {
        switch guide.placement {
        case .below: return "arrow.up"
        case .beside: return "arrow.left"
        case .unknown: return nil
        }
    }
}

/// The app icon as a drag source, the way Finder drags an app: the pasteboard carries the
/// bundle's file URL, which the System Settings privacy lists accept. (SwiftUI's `onDrag`
/// hands over an item provider that newer System Settings doesn't take.)
private struct AppIconDragSource: NSViewRepresentable {
    let icon: NSImage

    func makeNSView(context: Context) -> DragView { DragView(icon: icon) }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        let icon: NSImage
        private var downEvent: NSEvent?

        init(icon: NSImage) {
            self.icon = icon
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }

        // The guide panel never becomes key; the first click must start the drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let downEvent else { return }
            self.downEvent = nil
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: downEvent, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
