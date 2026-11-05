import OSLog
import ServiceManagement

private let log = Logger(subsystem: "app.gleaner.Gleaner", category: "login")

/// Launch at login, through `SMAppService`.
enum LoginItem {
    enum State {
        case enabled
        /// Registered, but the user still has to allow it in System Settings → General → Login Items.
        case requiresApproval
        case disabled
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    static var isInstalled: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Updating launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Turns launch at login on the first time the installed app runs, and re-registers it when
    /// the app was moved or renamed since. Development builds in the build folder are left alone.
    static func configureOnFirstLaunch(settings: inout AppSettings) {
        guard isInstalled else { return }
        if !settings.launchAtLoginConfigured {
            settings.launchAtLoginConfigured = true
            settings.launchAtLogin = true
        }
        if settings.launchAtLogin && state == .disabled {
            setEnabled(true)
        }
    }
}
