import AppKit

/// Starts the app with AppKit: Gleaner has no windows of its own besides the menu bar panel,
/// which `MenuBarController` manages, so a SwiftUI `App` would only add an empty scene.
@main
enum GleanerApp {
    @MainActor
    static func main() {
        // Only one copy should watch notifications and own a menu bar item.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Never shown (Gleaner has no menu bar of its own), but text fields get ⌘C, ⌘V, ⌘X, ⌘A and
    /// ⌘Z through it.
    static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        main.addItem(NSMenuItem())  // The application menu slot.
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    private var model: AppModel?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement; this also covers runs from the build folder.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()
        let model = AppModel()
        self.model = model
        menuBar = MenuBarController(model: model)
        _ = Updater.shared
    }
}
