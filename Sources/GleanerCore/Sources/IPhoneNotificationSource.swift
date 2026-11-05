import Foundation

/// Reads notifications forwarded from the user's iPhone ("iPhone notifications" on macOS 15+).
///
/// macOS keeps them apart from the Mac's own notification database: one folder per iPhone
/// app, each holding a keyed archive of the notifications still in Notification Center.
///
/// - The format is undocumented; this matches what macOS 15–27 write.
/// - Reading it requires Full Disk Access.
/// - Notifications the user dismisses disappear from the files, so they must be polled.
/// - If the feature is off, the folder does not exist and this source simply returns nothing.
public struct IPhoneNotificationSource: NotificationSource {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.UserNotifications/Library/UserNotifications/Remote/default")

    static let fileName = "DeliveredNotifications.plist"

    public let directory: URL

    public init(directory: URL = IPhoneNotificationSource.defaultDirectory) {
        self.directory = directory
    }

    public func changeToken() -> Date? {
        archiveFiles().compactMap(\.modified).max()
    }

    public func fetch(after date: Date) throws -> [AppNotification] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []  // Feature not in use.
        }
        guard (try? fm.contentsOfDirectory(atPath: directory.path)) != nil else {
            throw NotificationSourceError.accessDenied
        }

        var result: [AppNotification] = []
        for file in archiveFiles() {
            // A file not written since `date` cannot hold anything delivered after it.
            if let modified = file.modified, modified <= date { continue }
            guard let data = try? Data(contentsOf: file.url) else { continue }
            result += RemoteNotificationArchive.notifications(in: data).filter { $0.date > date }
        }
        return result.sorted { $0.date < $1.date }
    }

    private func archiveFiles() -> [(url: URL, modified: Date?)] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            let url = folder.appendingPathComponent(Self.fileName)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return (url, attributes[.modificationDate] as? Date)
        }
    }
}

/// Decodes a `DeliveredNotifications.plist` keyed archive.
///
/// Decoding is done with secure coding and a fixed allow-list of Foundation value types.
/// The archive also contains private system classes (Do Not Disturb metadata); those are
/// never instantiated but replaced by `ArchivedOpaqueObject`, which reads only the one
/// string we need from them: the app's bundle identifier.
///
/// The replacement is applied to every non-Foundation class name found in the archive,
/// not only to classes missing from the process: an AppKit app has the Do Not Disturb
/// classes loaded, and secure decoding would otherwise reject the whole file.
enum RemoteNotificationArchive {
    static let allowedClasses: [AnyClass] = [
        NSArray.self, NSDictionary.self, NSString.self, NSNumber.self, NSDate.self,
        NSData.self, NSURL.self, NSUUID.self, NSSet.self, ArchivedOpaqueObject.self,
    ]

    /// Archived class names decoded as themselves; everything else becomes `ArchivedOpaqueObject`.
    static let foundationClassNames: Set<String> = [
        "NSArray", "NSMutableArray", "NSDictionary", "NSMutableDictionary", "NSString", "NSMutableString",
        "NSNumber", "NSDate", "NSData", "NSMutableData", "NSURL", "NSUUID", "NSSet", "NSMutableSet",
    ]

    /// The `$classname`s an archive refers to, read without decoding any object.
    static func classNames(in data: Data) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return [] }
        return Set(objects.compactMap { ($0 as? [String: Any])?["$classname"] as? String })
    }

    static func notifications(in data: Data) -> [AppNotification] {
        guard let records = decode(data) else { return [] }
        return records.compactMap(notification(from:))
    }

    static func decode(_ data: Data) -> [[String: Any]]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        let substitution = OpaqueClassSubstitution()
        for name in classNames(in: data) where !foundationClassNames.contains(name) {
            unarchiver.setClass(ArchivedOpaqueObject.self, forClassName: name)
        }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.delegate = substitution
        let root = unarchiver.decodeObject(of: allowedClasses, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        guard unarchiver.error == nil else { return nil }
        return root as? [[String: Any]] ?? []
    }

    static func notification(from record: [String: Any]) -> AppNotification? {
        guard let identifier = record["AppNotificationIdentifier"] as? String,
              let date = record["AppNotificationCreationDate"] as? Date else { return nil }
        let bundleID = (record["EventBehavior"] as? ArchivedOpaqueObject)?.bundleIdentifier
        return AppNotification(
            id: "iphone-\(identifier)",
            appID: bundleID ?? "iphone.unknown",
            title: record["AppNotificationTitle"] as? String ?? "",
            subtitle: record["AppNotificationSubtitle"] as? String ?? "",
            body: record["AppNotificationMessage"] as? String ?? "",
            date: date,
            origin: .iPhone,
            isOneTimePasscode: (record["ContainsOneTimePasscode"] as? Bool) ?? false,
            mentionsUser: (record["CommunicationContextMentionsCurrentUser"] as? Bool) ?? false
        )
    }
}

/// Stand-in for private classes found in the archive. Reads `bundleIdentifier`, directly or
/// through a nested `eventDetails` object, and ignores everything else.
@objc(GleanerArchivedOpaqueObject)
final class ArchivedOpaqueObject: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let bundleIdentifier: String?

    init(bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
        super.init()
    }

    required init?(coder: NSCoder) {
        let nested = coder.decodeObject(of: ArchivedOpaqueObject.self, forKey: "eventDetails")
        bundleIdentifier = coder.decodeObject(of: NSString.self, forKey: "bundleIdentifier") as String?
            ?? nested?.bundleIdentifier
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(bundleIdentifier, forKey: "bundleIdentifier")
    }
}

/// Fallback for class names missed by the pre-scan: maps any class the unarchiver cannot
/// find to `ArchivedOpaqueObject`.
private final class OpaqueClassSubstitution: NSObject, NSKeyedUnarchiverDelegate {
    func unarchiver(_ unarchiver: NSKeyedUnarchiver, cannotDecodeObjectOfClassName name: String,
                    originalClasses classNames: [String]) -> AnyClass? {
        ArchivedOpaqueObject.self
    }
}
