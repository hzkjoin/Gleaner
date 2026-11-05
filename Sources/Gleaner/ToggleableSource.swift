import Foundation
import GleanerCore

/// A thread-safe on/off flag the main actor flips and sources read from the pipeline.
final class SourceSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A source that can be turned off from settings without rebuilding the pipeline.
struct ToggleableSource: NotificationSource {
    let source: NotificationSource
    let toggle: SourceSwitch

    func changeToken() -> Date? {
        toggle.isOn ? source.changeToken() : nil
    }

    func fetch(after date: Date) throws -> [AppNotification] {
        toggle.isOn ? try source.fetch(after: date) : []
    }
}

/// Drops notifications from apps another source reads directly (Mail, when the mail source is on),
/// so they aren't processed twice.
struct ExcludingSource: NotificationSource {
    let source: NotificationSource
    let excludedApps: Set<String>
    let when: SourceSwitch

    func changeToken() -> Date? { source.changeToken() }

    func fetch(after date: Date) throws -> [AppNotification] {
        let notes = try source.fetch(after: date)
        guard when.isOn else { return notes }
        return notes.filter { !excludedApps.contains($0.appID.lowercased()) }
    }
}
