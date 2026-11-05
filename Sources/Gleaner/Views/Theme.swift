import AppKit
import GleanerCore
import SwiftUI

/// Visual system: an opaque neutral canvas, white cards, ink-colored primary actions.
///
/// Colors are explicit rather than semantic (`.primary`, `.secondary`) on purpose: the
/// menu bar window sits on a translucent material, and semantic label colors become
/// "vibrant" there, blending with the wallpaper and looking washed out.
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    // Surfaces
    static let canvas = dynamic(light: hex(0xF5F5F7), dark: hex(0x1C1C1E))
    static let card = dynamic(light: hex(0xFFFFFF), dark: hex(0x2A2A2D))
    static let cardStroke = dynamic(light: hex(0x000000, 0.06), dark: hex(0xFFFFFF, 0.07))
    static let cardStrokeHover = dynamic(light: hex(0x000000, 0.14), dark: hex(0xFFFFFF, 0.16))
    /// Boxes inside a card (suggested reply, code).
    static let inset = dynamic(light: hex(0xF4F4F6), dark: hex(0x343437))
    static let subtleFill = dynamic(light: hex(0x000000, 0.05), dark: hex(0xFFFFFF, 0.08))
    static let divider = dynamic(light: hex(0x000000, 0.07), dark: hex(0xFFFFFF, 0.08))

    // Text
    static let textPrimary = dynamic(light: hex(0x1D1D1F), dark: hex(0xF5F5F7))
    static let textSecondary = dynamic(light: hex(0x6E6E73), dark: hex(0xA1A1A6))
    static let textTertiary = dynamic(light: hex(0x8E8E93), dark: hex(0x7C7C80))

    // Actions and signals
    static let ink = dynamic(light: hex(0x1D1D1F), dark: hex(0xF5F5F7))
    static let onInk = dynamic(light: hex(0xFFFFFF), dark: hex(0x1D1D1F))
    static let urgent = dynamic(light: hex(0xE5484D), dark: hex(0xFF6369))
    static let positive = dynamic(light: hex(0x30A46C), dark: hex(0x4CC38A))
    static let caution = dynamic(light: hex(0xE38A1A), dark: hex(0xF1A10D))

    static let cardRadius: CGFloat = 12
    static let insetRadius: CGFloat = 8
    static let panelWidth: CGFloat = 392
    static let horizontalPadding: CGFloat = 16
}

/// Presentation details for each kind of item.
extension ActionKind {
    var title: String {
        switch self {
        case .code: return "验证码"
        case .reply: return "需要回复"
        case .task: return "待办"
        case .alert: return "提醒"
        case .notice: return "值得关注"
        }
    }

    var symbol: String {
        switch self {
        case .code: return "key.horizontal"
        case .reply: return "arrowshape.turn.up.left"
        case .task: return "checklist"
        case .alert: return "exclamationmark.triangle"
        case .notice: return "eye"
        }
    }

    /// Order of sections in the panel: the most time-sensitive first.
    static let displayOrder: [ActionKind] = [.code, .reply, .task, .alert, .notice]
}

/// A small dark label shown after hovering for a moment. Menu bar panels never become the
/// active window, so the system tooltips from `.help` do not appear reliably there.
///
/// Hints are drawn by `hintLayer()` at the root of the panel, above everything else, so later
/// content cannot cover them; the most recently shown hint wins when several are active.
struct HoverHint: ViewModifier {
    let text: String
    /// Place the hint at the pointer rather than under the view; for large areas such as cards.
    var followsPointer = false

    @State private var shownAt: Date?
    @State private var inside = false
    @State private var pointer: CGPoint = .zero
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if followsPointer {
                        // Like a system tooltip: hide while moving, show once the pointer rests.
                        pointer = location
                        shownAt = nil
                        schedule()
                    } else if !inside {
                        inside = true
                        schedule()
                    }
                case .ended:
                    inside = false
                    pending?.cancel()
                    shownAt = nil
                }
            }
            .transformAnchorPreference(key: HintPreferenceKey.self, value: .bounds) { value, anchor in
                guard let shownAt else { return }
                let mine = HintRequest(text: text, anchor: anchor, pointer: followsPointer ? pointer : nil, shownAt: shownAt)
                HintPreferenceKey.reduce(value: &value) { mine }
            }
            .onDisappear { pending?.cancel() }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(followsPointer ? 700 : 450))
            if !Task.isCancelled { shownAt = Date() }
        }
    }
}

struct HintRequest {
    /// Hints of small controls (buttons, file rows) win over pointer hints of the cards around them.
    var isPointer: Bool { pointer != nil }

    let text: String
    let anchor: Anchor<CGRect>
    /// Pointer location inside the anchor's bounds, for hints that follow the pointer.
    let pointer: CGPoint?
    let shownAt: Date
}

struct HintPreferenceKey: PreferenceKey {
    static let defaultValue: HintRequest? = nil

    static func reduce(value: inout HintRequest?, nextValue: () -> HintRequest?) {
        guard let next = nextValue() else { return }
        if let current = value, !current.isPointer || next.isPointer, !(current.isPointer == next.isPointer && current.shownAt < next.shownAt) {
            return
        }
        value = next
    }
}

/// Draws the active hint above the content, kept inside the container.
private struct HintBubble: View {
    let request: HintRequest
    let target: CGRect
    let container: CGSize
    @State private var size: CGSize = .zero

    var body: some View {
        Text(request.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.onInk)
            .lineLimit(5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: min(max(size.height / 2, 6), 10), style: .continuous)
                .fill(Theme.ink.opacity(0.9)))
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .position(position)
            .opacity(size == .zero ? 0 : 1)
            .allowsHitTesting(false)
    }

    private var position: CGPoint {
        let margin: CGFloat = 6
        let gap: CGFloat = request.pointer == nil ? 5 : 18
        let anchorX = request.pointer.map { target.minX + $0.x } ?? target.midX
        let top = request.pointer.map { target.minY + $0.y } ?? target.minY
        let bottom = request.pointer.map { target.minY + $0.y } ?? target.maxY
        let x = min(max(anchorX, margin + size.width / 2), container.width - margin - size.width / 2)
        var y = bottom + gap + size.height / 2
        if y + size.height / 2 > container.height - margin {
            // Not enough room below: show above.
            y = top - (request.pointer == nil ? gap : 8) - size.height / 2
        }
        return CGPoint(x: x, y: max(y, margin + size.height / 2))
    }
}

extension View {
    func hoverHint(_ text: String, followsPointer: Bool = false) -> some View {
        modifier(HoverHint(text: text, followsPointer: followsPointer))
    }

    /// Hosts the hints of the views inside; apply once at the root of a window.
    func hintLayer() -> some View {
        overlayPreferenceValue(HintPreferenceKey.self) { request in
            GeometryReader { proxy in
                if let request {
                    HintBubble(request: request, target: proxy[request.anchor], container: proxy.size)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: request?.shownAt)
        }
    }
}

/// A small circular icon button that highlights on hover.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Theme.subtleFill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverHint(help)
    }
}

/// An icon that opens a menu, styled like `IconButton`.
struct IconMenu<Content: View>: View {
    let symbol: String
    let help: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .background(Circle().fill(hovering ? Theme.subtleFill : .clear))
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .hoverHint(help)
    }
}

/// A small capsule segmented control.
struct SegmentedTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let tabs: [(value: Value, title: String, count: Int?)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.value) { tab in
                let selected = selection == tab.value
                Button {
                    selection = tab.value
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.title)
                        if let count = tab.count, count > 0 {
                            Text("\(count)").foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(selected ? Theme.card : .clear)
                            .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 0.5)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.subtleFill))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact capsule button. `prominent` uses the ink color for the primary action.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(prominent ? Theme.onInk : Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Theme.ink : Theme.subtleFill))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Date {
    /// "刚刚", "5 分钟前", "昨天"…
    var relativeDescription: String {
        if Date().timeIntervalSince(self) < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

/// The last row of a long list: shows the next page.
struct LoadMoreRow: View {
    /// How many rows are not shown yet.
    let remaining: Int
    let action: () -> Void
    @State private var hovering = false

    /// Rows added per page.
    static let pageSize = 30

    var body: some View {
        Button(action: action) {
            Text("还有 \(remaining) 条")
                .font(.system(size: 12))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
