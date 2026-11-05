import AppKit
import SwiftUI

extension View {
    /// Makes the whole view a click target, with a pointing-hand cursor on hover.
    /// Buttons inside the view keep handling their own clicks.
    func clickable(action: @escaping () -> Void) -> some View {
        modifier(Clickable(action: action))
    }
}

private struct Clickable: ViewModifier {
    let action: () -> Void
    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { inside in
                if inside && !cursorPushed {
                    NSCursor.pointingHand.push()
                    cursorPushed = true
                } else if !inside {
                    popCursor()
                }
            }
            // A view removed while hovered (e.g. an item marked done) gets no hover exit.
            .onDisappear(perform: popCursor)
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

/// Closes the menu bar panel, e.g. after handing off to another app.
@MainActor
enum PanelDismissal {
    /// Set by `MenuBarController`.
    static var handler: (() -> Void)?

    static func dismiss() { handler?() }
}
