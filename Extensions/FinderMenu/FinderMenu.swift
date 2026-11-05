import Cocoa
import FinderSync

/// The Finder extension: adds 问问拾穗 to the right-click menu of files Gleaner can read, which
/// opens Gleaner's question page with the selected files attached.
final class FinderMenu: FIFinderSync {
    private static let started = Notification.Name("app.gleaner.Gleaner.FinderMenu.started")

    override init() {
        super.init()
        // Every folder, including other disks.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Volumes")]
        // When the extension is reloaded (an update, turned off and on) the old process keeps
        // running and Finder shows both menus. The newest copy announces itself; older ones quit.
        let me = String(getpid())
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Self.started, object: nil, queue: .main) { note in
            guard let other = note.object as? String, other != me else { return }
            exit(0)
        }
        center.postNotificationName(Self.started, object: me, userInfo: nil, deliverImmediately: true)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems, !selectedFiles.isEmpty else { return nil }
        // Only when every selected item can be read; folders and other files can't be attached.
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard selected.count == selectedFiles.count else { return nil }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "问问拾穗", action: #selector(ask(_:)), keyEquivalent: "")
        item.image = Self.icon
        menu.addItem(item)
        return menu
    }

    @objc private func ask(_ sender: AnyObject?) {
        let files = selectedFiles
        guard !files.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "gleaner"
        components.host = "ask"
        components.queryItems = files.map { URLQueryItem(name: "file", value: $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// Selected files Gleaner can read; folders and other files are left out.
    private var selectedFiles: [URL] {
        (FIFinderSyncController.default().selectedItemURLs() ?? [])
            .filter { $0.isFileURL && !$0.hasDirectoryPath && ReadableFileTypes.contains($0) }
    }

    /// Gleaner's icon: the extension sits in Gleaner.app/Contents/PlugIns.
    private static let icon: NSImage = {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }()
}
