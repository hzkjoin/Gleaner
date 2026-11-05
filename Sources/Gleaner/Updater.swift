import AppKit
import Combine
import Sparkle

/// In-app updates through Sparkle, from the feed named by `SUFeedURL` in Info.plist.
///
/// Off for builds without a feed (development) and for copies run from the build folder, so
/// working on Gleaner never replaces the build with a release.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    @Published var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    var isAvailable: Bool { controller != nil }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private init() {
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        let installed = !Bundle.main.bundleURL.path.contains("/build/")
        if !feed.isEmpty && installed {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    func checkForUpdates() {
        // Sparkle's windows need the app in front; a menu bar app usually isn't.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}
