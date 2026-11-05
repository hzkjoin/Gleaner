import Foundation
import SQLite3

/// Reads the notification center database that macOS keeps on disk.
///
/// - The database is undocumented; this matches the layout used since macOS 15.
/// - Reading it requires Full Disk Access.
/// - To avoid interfering with `usernoted`, each fetch copies `db` and `db-wal`
///   into a temporary directory, reads the copy, and deletes it.
public struct MacNotificationCenterSource: NotificationSource {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2")

    public let directory: URL

    public init(directory: URL = MacNotificationCenterSource.defaultDirectory) {
        self.directory = directory
    }

    /// Whether this process may read the notification database (Full Disk Access).
    public static func hasAccess(directory: URL = defaultDirectory) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil
    }

    public func changeToken() -> Date? {
        ["db", "db-wal"].compactMap { name -> Date? in
            let path = directory.appendingPathComponent(name).path
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.max()
    }

    public func fetch(after date: Date) throws -> [AppNotification] {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: directory.path)) != nil else {
            throw NotificationSourceError.accessDenied
        }

        let workDir = fm.temporaryDirectory.appendingPathComponent("gleaner-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let dbCopy = workDir.appendingPathComponent("db")
        do {
            try fm.copyItem(at: directory.appendingPathComponent("db"), to: dbCopy)
        } catch {
            throw NotificationSourceError.accessDenied
        }
        // The WAL holds recent notifications not yet checkpointed into the main file.
        // `-shm` is intentionally not copied; SQLite rebuilds it from the WAL.
        try? fm.copyItem(at: directory.appendingPathComponent("db-wal"),
                         to: workDir.appendingPathComponent("db-wal"))

        return try Self.read(databaseAt: dbCopy, after: date)
    }

    static func read(databaseAt url: URL, after date: Date) throws -> [AppNotification] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(db)
            throw NotificationSourceError.unreadable(message)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT hex(r.uuid), r.rec_id, a.identifier, r.data, r.delivered_date
            FROM record r JOIN app a ON a.app_id = r.app_id
            WHERE r.delivered_date > ?
            ORDER BY r.delivered_date ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NotificationSourceError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSinceReferenceDate)

        var result: [AppNotification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let recordID = sqlite3_column_int64(stmt, 1)
            let appID = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "unknown"
            let delivered = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))

            var content = Content()
            if let bytes = sqlite3_column_blob(stmt, 3) {
                content = Content(plist: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 3))))
            }

            let id = uuid.isEmpty ? "\(recordID)-\(delivered.timeIntervalSinceReferenceDate)" : uuid
            result.append(AppNotification(id: id, appID: appID, title: content.title,
                                          subtitle: content.subtitle, body: content.body, date: delivered))
        }
        return result
    }

    /// The text fields of a notification record's binary plist (`req.titl`, `req.subt`, `req.body`).
    struct Content {
        var title = ""
        var subtitle = ""
        var body = ""

        init() {}

        init(plist data: Data) {
            guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let request = root["req"] as? [String: Any] else { return }
            title = request["titl"] as? String ?? ""
            subtitle = request["subt"] as? String ?? ""
            body = request["body"] as? String ?? ""
        }
    }
}
