import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "app.gleaner.Gleaner", category: "wechat")

/// Opens a chat in WeChat for Mac by searching for its name, and optionally pastes a reply into
/// its input box. The reply is never sent.
///
/// WeChat 4 exposes nothing of its window to Accessibility, but its menu bar works. So search,
/// select-all and paste go through the menus rather than key presses, and the one key press
/// needed, Return to open the top result, is sent only while WeChat's search drop-down is on
/// screen. That drop-down exists only while the search field has focus, so Return cannot land
/// in a chat's input box. Anything unexpected stops the attempt and leaves WeChat in front.
///
/// Logs say which step stopped an attempt, never the chat's name.
@MainActor
enum WeChatLocator {
    static let bundleID = "com.tencent.xinWeChat"
    /// WeChat for Mac, and WeChat on an iPhone forwarding its notifications.
    private static let appIDs: Set<String> = ["com.tencent.xinwechat", "com.tencent.xin"]

    static func handles(_ appID: String) -> Bool { appIDs.contains(appID.lowercased()) }

    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to the Accessibility setting.
    static func requestTrust() {
        // The value of kAXTrustedCheckOptionPrompt.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static var busy = false

    /// Brings WeChat forward on the chat named `conversation`. With a `reply`, also pastes it into
    /// the input box and leaves it on the clipboard. False when the chat could not be opened; WeChat
    /// is then in front as it was, and the reply (if any) is on the clipboard.
    @discardableResult
    static func open(conversation: String, reply: String? = nil) async -> Bool {
        let name = conversation.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = Date()
        func stop(_ reason: String) -> Bool {
            log.error("Stopped: \(reason, privacy: .public) after \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
            return false
        }
        guard !busy else { return stop("already running") }
        busy = true
        defer { busy = false }

        let pasteboard = NSPasteboard.general
        let saved = reply == nil ? PasteboardSnapshot(pasteboard) : nil
        defer {
            if let reply {
                Clipboard.copy(reply)
            } else {
                saved?.restore(to: pasteboard)
            }
        }

        guard let app = await activate() else { return stop("WeChat did not come to the front") }
        guard !name.isEmpty, !["微信", "WeChat"].contains(name) else { return stop("no chat name") }
        guard isTrusted else {
            requestTrust()
            return stop("no Accessibility access")
        }
        let pid = app.processIdentifier
        let menu = Menu(pid: pid)

        // The chat list, in the main window.
        menu.press("1")
        guard let window = await poll(seconds: 1.5, { mainWindow(pid: pid) }) else { return stop("no main window") }

        // Search, and wait for the drop-down below the search field. If WeChat's window lost the
        // keyboard (to Gleaner's panel) while WeChat stayed in front, search does nothing; switching
        // away and back gives the window the keyboard again.
        var found: Window?
        for attempt in 0..<2 {
            if attempt > 0 {
                log.info("Search drop-down missing; switching to WeChat again")
                guard await reactivate() != nil else { break }
            }
            guard menu.press("f") else { return stop("search menu item not found") }
            found = await poll(seconds: 0.8, { searchPopup(pid: pid, below: window) })
            if found != nil { break }
        }
        guard let popup = found else { return stop("search drop-down did not appear") }

        // Replace whatever the field held with the name.
        Clipboard.copy(name)
        menu.press("a")
        guard menu.press("v") else { return stop("paste menu item not found") }
        guard await resultsSettled(pid: pid, popup: popup) else { return stop("drop-down closed before Return") }

        // Return only while the drop-down is up, which means the search field has focus.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              bounds(of: popup.id, pid: pid) != nil else { return stop("focus changed before Return") }
        let windowsBefore = Set(windows(pid: pid).filter { $0.layer == 0 }.map(\.id))
        pressReturn()

        let closed = await poll(seconds: 1.5) { bounds(of: popup.id, pid: pid) == nil ? true : nil }
        guard closed == true else {
            return stop("Return did not open a result")
        }
        // The top result was a web search, which opens its own window.
        if windows(pid: pid).contains(where: { $0.layer == 0 && !windowsBefore.contains($0.id) }) {
            menu.press("w")
            return stop("top result was not a chat")
        }

        if let reply {
            try? await Task.sleep(for: .milliseconds(150))
            Clipboard.copy(reply)
            menu.press("v")
        }
        log.info("Opened chat in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
        return true
    }

    // MARK: - App

    /// Opens WeChat like a click on its Dock icon, which also brings back a closed main window.
    /// When WeChat is already in front, first switches away: its window may have lost the
    /// keyboard to Gleaner's panel, and opening an app already in front changes nothing.
    private static func activate() async -> NSRunningApplication? {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() == bundleID.lowercased() {
            return await reactivate()
        }
        return await open()
    }

    /// Makes Gleaner the active app for a moment, then WeChat again.
    private static func reactivate() async -> NSRunningApplication? {
        NSApp.activate()
        _ = await poll(seconds: 0.5) { NSApp.isActive ? true : nil }
        return await open()
    }

    private static func open() async -> NSRunningApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return await poll(seconds: 3) {
            let front = NSWorkspace.shared.frontmostApplication
            return front?.bundleIdentifier?.lowercased() == bundleID.lowercased() ? front : nil
        }
    }

    /// Return, for the app in front (the caller has checked it is WeChat).
    private static func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Windows

    struct Window {
        var id: CGWindowID
        var layer: Int
        var frame: CGRect
    }

    /// WeChat's on-screen windows: numbers, layers and frames only.
    private static func windows(pid: pid_t) -> [Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw) else { return nil }
            return Window(id: id, layer: layer, frame: frame)
        }
    }

    private static func mainWindow(pid: pid_t) -> Window? {
        windows(pid: pid).filter { $0.layer == 0 && $0.frame.width > 400 && $0.frame.height > 300 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The search drop-down: a floating window hanging from the search field at the top left of
    /// the main window.
    private static func searchPopup(pid: pid_t, below window: Window) -> Window? {
        windows(pid: pid).first { popup in
            let dx = popup.frame.minX - window.frame.minX
            let dy = popup.frame.minY - window.frame.minY
            return popup.layer > 0 && (10...160).contains(dx) && (15...90).contains(dy)
                && (240...700).contains(popup.frame.width)
        }
    }

    private static func bounds(of id: CGWindowID, pid: pid_t) -> CGRect? {
        windows(pid: pid).first { $0.id == id }?.frame
    }

    /// Waits for search results: the drop-down changes height as they arrive, then holds still.
    /// False if the drop-down went away.
    private static func resultsSettled(pid: pid_t, popup: Window) async -> Bool {
        var last = popup.frame.height
        var changed = false
        var steady = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            guard let frame = bounds(of: popup.id, pid: pid) else { return false }
            if frame.height != last {
                last = frame.height
                changed = true
                steady = 0
            } else {
                steady += 1
                // Settled: still for 300 ms after a change, or no change at all for 800 ms.
                if (changed && steady >= 6) || steady >= 16 { return true }
            }
        }
        return bounds(of: popup.id, pid: pid) != nil
    }

    private static func poll<T>(seconds: Double, _ check: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let value = check() { return value }
            try? await Task.sleep(for: .milliseconds(40))
        } while Date() < deadline
        return check()
    }

    // MARK: - Menus

    /// WeChat's menu items, found by their ⌘ shortcut so the menu language doesn't matter.
    private struct Menu {
        let app: AXUIElement

        init(pid: pid_t) {
            app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
        }

        /// Presses the enabled item whose shortcut is ⌘ plus `key`. False if there is none.
        @discardableResult
        func press(_ key: String) -> Bool {
            guard let item = item(for: key) else { return false }
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }

        private func item(for key: String) -> AXUIElement? {
            guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return nil }
            for top in children(bar).dropFirst() {  // Skip the Apple menu.
                for menu in children(top) {
                    for item in children(menu) {
                        let char: String? = attribute(item, kAXMenuItemCmdCharAttribute)
                        let modifiers: NSNumber? = attribute(item, kAXMenuItemCmdModifiersAttribute)
                        let enabled: Bool? = attribute(item, kAXEnabledAttribute)
                        // Modifiers 0 means ⌘ alone.
                        if char?.lowercased() == key, modifiers?.intValue == 0, enabled == true { return item }
                    }
                }
            }
            return nil
        }

        private func children(_ element: AXUIElement) -> [AXUIElement] {
            attribute(element, kAXChildrenAttribute) ?? []
        }

        private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? T
        }
    }
}

/// The clipboard's contents, to put back after borrowing it.
private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        })
    }
}
