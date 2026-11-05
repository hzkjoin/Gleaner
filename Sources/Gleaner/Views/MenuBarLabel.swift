import SwiftUI

/// The text shown in the menu bar: 🌾, the number of open items, and optionally the most urgent one.
@MainActor
enum MenuBarLabel {
    /// Keeps the label short enough to survive a crowded menu bar.
    private static let maxSummaryLength = 8

    static func title(for model: AppModel) -> String {
        if let code = model.flashingCode { return "🔑 \(code)" }
        if let event = model.imminentEvent {
            let time = event.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            return "\(event.kind == .reminder ? "⏰" : "🗓") \(time) \(event.title.prefix(maxSummaryLength))"
        }
        if model.status == .accessDenied { return "🌾 !" }
        let items = model.menuBarItems
        guard let top = items.first else {
            // Nothing to act on: show the newest notice, without a count.
            if model.settings.showTopItemInMenuBar, let notice = model.latestNotice {
                return "🌾 \(shortened(notice.summary))"
            }
            return "🌾"
        }

        var text = "🌾 \(items.count)"
        if model.settings.showTopItemInMenuBar {
            text += " \(shortened(top.summary))"
        }
        return text
    }

    private static func shortened(_ summary: String) -> String {
        summary.count > maxSummaryLength ? summary.prefix(maxSummaryLength) + "…" : summary
    }
}
