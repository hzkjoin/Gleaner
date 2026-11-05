import Foundation

/// Which device a notification was delivered on.
public enum DeviceOrigin: String, Codable, Sendable {
    case mac
    /// Forwarded from the user's iPhone ("iPhone notifications" on macOS).
    case iPhone
}

/// A notification delivered by some app, as read from a `NotificationSource`.
public struct AppNotification: Identifiable, Hashable, Sendable {
    /// Stable identifier, unique within its source.
    public let id: String
    /// Bundle identifier of the app that posted the notification, e.g. `com.tencent.xinwechat`.
    public let appID: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let date: Date
    public let origin: DeviceOrigin
    /// The system flagged this notification as containing a one-time passcode.
    public let isOneTimePasscode: Bool
    /// The system determined that this message mentions the user.
    public let mentionsUser: Bool
    /// A received file on disk, for file notifications.
    public let attachmentPath: String?
    /// Sent by the user (Messages only). Kept as context, never analyzed.
    public let isFromUser: Bool

    public init(
        id: String,
        appID: String,
        title: String,
        subtitle: String = "",
        body: String,
        date: Date,
        origin: DeviceOrigin = .mac,
        isOneTimePasscode: Bool = false,
        mentionsUser: Bool = false,
        attachmentPath: String? = nil,
        isFromUser: Bool = false
    ) {
        self.id = id
        self.appID = appID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
        self.origin = origin
        self.isOneTimePasscode = isOneTimePasscode
        self.mentionsUser = mentionsUser
        self.attachmentPath = attachmentPath
        self.isFromUser = isFromUser
    }

    /// Whether the notification carries any text worth analyzing.
    public var hasContent: Bool {
        !(title + subtitle + body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
