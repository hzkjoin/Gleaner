import AppKit
import GleanerCore
import SwiftUI

/// Walks the user through granting Full Disk Access.
///
/// Opens the right System Settings pane and floats a small panel next to it with the app's
/// icon, which the user drags into the list. The panel never takes focus away from System
/// Settings, watches for access every second, and closes itself once access is granted.
@MainActor
final class AuthorizationGuide: ObservableObject {
    static let shared = AuthorizationGuide()

    /// Where the guide sits relative to System Settings, so it can point the right way.
    enum Placement { case below, beside, unknown }

    @Published private(set) var granted = false
    @Published private(set) var placement: Placement = .unknown

    private var panel: NSPanel?
    private var timer: Timer?
    private var onGranted: (() -> Void)?

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private static let systemSettingsBundleID = "com.apple.systempreferences"
    private static let gap: CGFloat = 14

    var isShowing: Bool { panel != nil }

    func start(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        granted = MacNotificationCenterSource.hasAccess()
        guard !granted else {
            onGranted()
            return
        }
        NSWorkspace.shared.open(Self.settingsURL)
        showPanel()
        startPolling()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Panel

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
        // System Settings takes a moment to open and size its window; follow it.
        for delay in [0.5, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let panel = self.panel else { return }
                self.place(panel)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // The SwiftUI content draws its own rounded background.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = FirstMouseHostingView(rootView: AuthorizationGuideView(guide: self))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    /// Below the System Settings window, or to its right when there is no room; centered
    /// low on the screen if System Settings cannot be found.
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin: NSPoint

        if let settings = Self.systemSettingsFrame() {
            origin = NSPoint(x: settings.midX - size.width / 2, y: settings.minY - size.height - Self.gap)
            placement = .below
            if origin.y < visible.minY {
                origin = NSPoint(x: settings.maxX + Self.gap, y: settings.minY + (settings.height - size.height) / 2)
                placement = .beside
            }
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.18)
            placement = .unknown
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// The System Settings window frame in AppKit coordinates (origin at the bottom left).
    private static func systemSettingsFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsBundleID).first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let frames = windows
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { info -> CGRect? in
                guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            }
        guard let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        // Window server coordinates start at the top left of the primary screen.
        return NSRect(x: largest.minX, y: primaryHeight - largest.maxY, width: largest.width, height: largest.height)
    }

    // MARK: - Watching for access

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAccess() }
        }
    }

    private func checkAccess() {
        guard MacNotificationCenterSource.hasAccess() else { return }
        granted = true
        timer?.invalidate()
        timer = nil
        onGranted?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.close() }
    }
}

/// Lets the icon be dragged on the first click while the panel stays non-key.
///
/// The panel must never become key: System Settings asks for the user's password right after
/// the drop, and a key panel would keep the keyboard focus away from that password field.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
