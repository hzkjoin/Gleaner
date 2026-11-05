import AppKit
import Combine

import SwiftUI

/// Owns the menu bar item and the panel that drops down from it.
///
/// SwiftUI's `MenuBarExtra` offers no way to close its window from code: on recent macOS the
/// status item's clicks are routed by the system, and closing the window directly leaves the
/// item stuck in its open state. Managing the item and panel here makes opening and closing
/// explicit, so the panel can close after handing off to another app.
@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: MenuPanel
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        let content = NSHostingController(rootView: PanelView().environmentObject(model))
        // The window follows the content's size; `MenuPanel` keeps its top edge under the menu bar.
        content.sizingOptions = [.preferredContentSize]
        panel = MenuPanel(content: content)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateTitle()
        // Coalesce bursts of model changes into one title update.
        model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        PanelDismissal.handler = { [weak self] in self?.close() }
        PanelDismissal.refocus = { [weak self] in
            guard let self, self.isOpen else { return }
            NSApp.activate()
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    var isOpen: Bool { panel.isVisible }

    /// The menu bar item's frame on screen.
    private var itemFrame: NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            isOpen ? close() : open()
        }
    }

    /// Right-click: the few things that don't need the panel.
    private func showMenu() {
        close()
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出拾穗", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettings() {
        model.route = .settings
        open()
    }

    func open() {
        guard !isOpen, let button = statusItem.button, let buttonWindow = button.window else { return }
        let screen = buttonWindow.screen ?? NSScreen.main
        panel.position(below: itemFrame, on: screen)
        // A non-activating panel takes the keyboard without bringing the app forward.
        panel.makeKeyAndOrderFront(nil)
        // Don't start with a text field focused and its text selected.
        panel.makeFirstResponder(nil)
        button.highlight(true)
        startMonitoring()
    }

    func close() {
        guard isOpen else { return }
        stopMonitoring()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    private func updateTitle() {
        statusItem.button?.title = MenuBarLabel.title(for: model)
    }

    /// Closes on a click outside, Escape, or another app coming forward.
    private func startMonitoring() {
        stopMonitoring()
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                // The menu bar item is drawn by the system, so clicks on it arrive here too;
                // those are handled by `toggle`.
                guard let self, !self.itemFrame.contains(NSEvent.mouseLocation), !PanelDismissal.isPickingFiles else { return }
                self.close()
            }
        }) {
            monitors.append(outside)
        }
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, event.window === self?.panel else { return event }
            self?.close()
            return nil
        }) {
            monitors.append(escape)
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard !PanelDismissal.isPickingFiles else { return }
                self?.close()
            }
        })
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }
}

/// A borderless panel with rounded corners and a shadow, like a menu bar window. It takes
/// keyboard focus for its text fields without activating the app.
final class MenuPanel: NSPanel {
    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow

        contentViewController = content
        content.view.wantsLayer = true
        content.view.layer?.cornerRadius = 12
        content.view.layer?.cornerCurve = .continuous
        content.view.layer?.masksToBounds = true
    }

    /// Whatever resizes the panel, its top edge stays put, so it grows and shrinks downward.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let anchorTop { frame.origin.y = anchorTop - frame.height }
        super.setFrame(frame, display: flag)
    }

    /// Where the top edge belongs, just under the menu bar item.
    private(set) var anchorTop: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Hangs the panel under the menu bar item, kept on screen.
    func position(below item: NSRect, on screen: NSScreen?) {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = max(frame.height, 120)
        var x = item.minX
        x = min(max(x, visible.minX + 8), visible.maxX - frame.width - 8)
        let top = item.minY - 5
        anchorTop = top
        setFrame(NSRect(x: x, y: top - height, width: Theme.panelWidth, height: height), display: false)
    }
}
