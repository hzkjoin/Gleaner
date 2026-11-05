import Foundation

/// A place notifications can be read from.
///
/// Implement this protocol to feed Gleaner from somewhere other than the macOS
/// notification center (an IMAP inbox, a chat API, ...).
public protocol NotificationSource: Sendable {
    /// A cheap value that changes whenever new notifications may be available.
    /// The pipeline polls it and calls `fetch(after:)` only when it changes.
    func changeToken() -> Date?

    /// Notifications delivered strictly after `date`, oldest first.
    func fetch(after date: Date) throws -> [AppNotification]
}

public enum NotificationSourceError: LocalizedError, Equatable {
    /// The process lacks permission to read the source (e.g. Full Disk Access).
    case accessDenied
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied: return "没有读取通知的权限，需要授予完全磁盘访问权限"
        case .unreadable(let message): return "读取通知失败：\(message)"
        }
    }
}
