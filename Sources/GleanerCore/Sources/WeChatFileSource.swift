import Foundation

/// Files received in WeChat for Mac (4.x), which stores them under
/// `xwechat_files/<account>/msg/file/<yyyy-MM>/`.
///
/// Each new file becomes a notification with `attachmentPath` set; the pipeline turns it into
/// an item by rule, without the model.
public struct WeChatFileSource: NotificationSource {
    public static let appID = "com.tencent.xinwechat"
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")

    public let root: URL

    public init(root: URL = WeChatFileSource.defaultRoot) {
        self.root = root
    }

    /// `msg/file/<month>` folders of every account, newest two months only.
    func monthFolders(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let months = [now, Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now].map(formatter.string)
        let accounts = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return accounts.flatMap { account in
            months.map { account.appendingPathComponent("msg/file/\($0)") }
        }.filter { fm.fileExists(atPath: $0.path) }
    }

    /// A received file by name, from the last two months, newest first; nil when not found.
    public func locate(fileNamed name: String, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        for folder in monthFolders(now: now).reversed() {
            let file = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    public func changeToken() -> Date? {
        monthFolders().compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }.max()
    }

    public func fetch(after date: Date) throws -> [AppNotification] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey, .fileSizeKey]
        var result: [AppNotification] = []
        for folder in monthFolders() {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles])) ?? []
            for file in files {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0,
                      let created = values.creationDate, created > date else { continue }
                result.append(AppNotification(
                    id: "wechat-file-\(file.path.hashValue)-\(Int(created.timeIntervalSince1970))",
                    appID: Self.appID,
                    title: "",
                    body: file.lastPathComponent,
                    date: created,
                    attachmentPath: file.path
                ))
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}

/// Turns received-file notifications into "收到文件" items, attributing them to the chat whose
/// notification mentions the file name.
public enum AttachmentRule {
    public static func items(in batch: [AppNotification], window: TimeInterval = 180) -> [ActionItem] {
        batch.compactMap { note in
            guard let path = note.attachmentPath else { return nil }
            let name = note.body
            let mention = batch.first {
                $0.attachmentPath == nil && $0.appID == note.appID && $0.body.contains(name)
                    && abs($0.date.timeIntervalSince(note.date)) <= window
            }
            return ActionItem(
                summary: "收到文件 \(name)",
                priority: .low,
                kind: .notice,
                appID: note.appID,
                origin: note.origin,
                sourceTitle: mention?.title ?? "",
                sourceExcerpt: name,
                notificationDate: note.date,
                sourceIDs: [note.id] + (mention.map { [$0.id] } ?? []),
                attachmentPath: path
            )
        }
    }
}
