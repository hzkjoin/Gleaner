import AppKit
import OSLog

private let log = Logger(subsystem: "app.gleaner.Gleaner", category: "apps")

/// Looks up apps by bundle identifier, with caching.
///
/// Mac apps are found through Launch Services. iPhone apps (for notifications forwarded from
/// the iPhone) are not installed on the Mac, but macOS keeps placeholder bundles for them for
/// iPhone Mirroring; their folder names carry the bundle identifier, and the `.app` inside is
/// named after the app. Placeholders only provide names and icons: they cannot be launched,
/// and there is no public way to open a specific app through iPhone Mirroring, so opening an
/// iPhone app opens iPhone Mirroring itself.
final class AppDirectory: @unchecked Sendable {
    static let shared = AppDirectory()

    private let lock = NSLock()
    private var names: [String: String] = [:]
    private var icons: [String: NSImage] = [:]
    private var placeholders: [String: URL] = [:]
    private var placeholdersIndexedAt: Date?

    /// How long a placeholder index is trusted before rescanning on a miss.
    private let placeholderIndexLifetime: TimeInterval = 600

    func url(for bundleID: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        return lock.withLock { placeholderURL(for: bundleID) }
    }

    /// Localized display name, falling back to the bundle identifier.
    func name(for bundleID: String) -> String {
        if let cached = lock.withLock({ names[bundleID] }) { return cached }
        var name = bundleID
        if let url = url(for: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
        }
        lock.withLock { names[bundleID] = name }
        return name
    }

    func icon(for bundleID: String) -> NSImage? {
        if let cached = lock.withLock({ icons[bundleID] }) { return cached }
        guard let url = url(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        lock.withLock { icons[bundleID] = icon }
        return icon
    }

    static let iPhoneMirroringID = "com.apple.ScreenContinuity"

    /// Whether `bundleID` is an iPhone app known only through a placeholder.
    func isIPhoneApp(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil
            && lock.withLock { placeholderURL(for: bundleID) } != nil
    }

    func open(_ bundleID: String) {
        if isIPhoneApp(bundleID), bundleID != Self.iPhoneMirroringID {
            open(Self.iPhoneMirroringID)
            return
        }
        guard let url = url(for: bundleID) else {
            log.error("cannot open \(bundleID, privacy: .public): app not found")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                log.error("opening \(bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// An app the user can pick, e.g. to ignore it.
    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        let isIPhone: Bool
    }

    /// Mac apps in the usual folders, and iPhone apps known through placeholders, sorted by name.
    /// Scans the disk; call off the main thread.
    func pickableApps() -> [Entry] {
        let fm = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var entries: [String: Entry] = [:]
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
                var display = fm.displayName(atPath: url.path)
                if display.hasSuffix(".app") { display.removeLast(4) }
                entries[id] = Entry(id: id, name: display, isIPhone: false)
            }
        }
        let iPhoneApps = lock.withLock { () -> [String: URL] in
            _ = placeholderURL(for: "")
            return placeholders
        }
        for (id, url) in iPhoneApps where entries[id] == nil {
            var display = fm.displayName(atPath: url.path)
            if display.hasSuffix(".app") { display.removeLast(4) }
            entries[id] = Entry(id: id, name: display, isIPhone: true)
        }
        return entries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A menu-sized copy of the app's icon.
    func smallIcon(for bundleID: String) -> NSImage? {
        guard let icon = icon(for: bundleID)?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    // MARK: - iPhone placeholders

    /// Call with `lock` held.
    private func placeholderURL(for bundleID: String) -> URL? {
        if let url = placeholders[bundleID] { return url }
        let stale = placeholdersIndexedAt.map { Date().timeIntervalSince($0) > placeholderIndexLifetime } ?? true
        guard stale else { return nil }
        placeholders = Self.indexPlaceholders()
        placeholdersIndexedAt = Date()
        return placeholders[bundleID]
    }

    /// `~/Library/Daemon Containers/<id>/Data/Library/Caches/Placeholders-v<n>.noindex/<bundle id>-<version>/<Name>.app`
    private static func indexPlaceholders() -> [String: URL] {
        let fm = FileManager.default
        let containers = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Daemon Containers")
        var index: [String: URL] = [:]
        for container in (try? fm.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? [] {
            let caches = container.appendingPathComponent("Data/Library/Caches")
            let roots = ((try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("Placeholders-") }
            for root in roots {
                for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    guard let app = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                        .first(where: { $0.pathExtension == "app" }),
                          let bundleID = Bundle(url: app)?.bundleIdentifier else { continue }
                    index[bundleID] = app
                }
            }
        }
        return index
    }
}
