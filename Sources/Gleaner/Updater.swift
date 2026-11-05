import AppKit
import Combine
import Sparkle
import UserNotifications

/// In-app updates through Sparkle, from the feed named by `SUFeedURL` in Info.plist.
///
/// Off for builds without a feed (development) and for copies run from the build folder, so
/// working on Gleaner never replaces the build with a release.
///
/// Scheduled checks remind gently: Gleaner lives in the menu bar and is rarely in front, so an
/// update window would open behind other apps. Instead the panel shows the new version, the menu
/// bar item gets a dot, and a notification is posted; any of them opens Sparkle's window.
/// Checks the user starts show the window right away.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()
    static let notificationID = "update-available"

    private var controller: SPUStandardUpdaterController?
    @Published var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    /// A newer version found by a scheduled check that the user hasn't looked at yet.
    @Published private(set) var availableVersion: String?

    var isAvailable: Bool { controller != nil }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private override init() {
        super.init()
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        let installed = !Bundle.main.bundleURL.path.contains("/build/")
        guard !feed.isEmpty && installed else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    /// Shows Sparkle's window: the pending update if one was found, otherwise a fresh check.
    func checkForUpdates() {
        // Sparkle's windows need the app in front; a menu bar app usually isn't.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    private func remind(of version: String) {
        availableVersion = version
        let content = UNMutableNotificationContent()
        content.title = "拾穗 \(version) 可以更新了"
        content.body = "点击查看"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    private func clearReminder() {
        availableVersion = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show its window only when Gleaner is already in front; otherwise remind gently.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { remind(of: version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { clearReminder() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { clearReminder() }
    }
}
