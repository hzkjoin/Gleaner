import Foundation
import SQLite3

/// Reads SMS, RCS and iMessage texts from the Messages database. The user's own messages are
/// included, flagged `isFromUser`, as context for replies; they are never analyzed.
///
/// Complements notifications: messages are still here after their notification is cleared,
/// blocked by a Focus, or shown without a preview. Requires Full Disk Access. Like the
/// notification database, the file is copied before reading.
public struct MessagesSource: NotificationSource {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages")
    public static let appID = "com.apple.MobileSMS"

    public let directory: URL

    public init(directory: URL = MessagesSource.defaultDirectory) {
        self.directory = directory
    }

    public func changeToken() -> Date? {
        ["chat.db", "chat.db-wal"].compactMap { name -> Date? in
            (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.modificationDate] as? Date
        }.max()
    }

    public func fetch(after date: Date) throws -> [AppNotification] {
        let fm = FileManager.default
        let database = directory.appendingPathComponent("chat.db")
        guard fm.fileExists(atPath: database.path) else { return [] }  // Messages never used.

        let workDir = fm.temporaryDirectory.appendingPathComponent("gleaner-messages-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        do {
            try fm.copyItem(at: database, to: workDir.appendingPathComponent("chat.db"))
        } catch {
            throw NotificationSourceError.accessDenied
        }
        try? fm.copyItem(at: directory.appendingPathComponent("chat.db-wal"), to: workDir.appendingPathComponent("chat.db-wal"))
        return try Self.read(databaseAt: workDir.appendingPathComponent("chat.db"), after: date)
    }

    static func read(databaseAt url: URL, after date: Date) throws -> [AppNotification] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw NotificationSourceError.unreadable("cannot open Messages database")
        }
        defer { sqlite3_close(db) }

        // `date` is nanoseconds since 2001 on current systems.
        let sql = """
            SELECT m.guid, m.text, m.date, h.id, c.display_name, m.is_from_me
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = j.chat_id
            WHERE m.text IS NOT NULL AND m.associated_message_type = 0 AND m.date > ?
            ORDER BY m.date ASC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NotificationSourceError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000))

        var result: [AppNotification] = []
        var seen = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
            }
            let guid = text(0)
            guard seen.insert(guid).inserted else { continue }  // A message can belong to several chats.
            let groupName = text(4)
            let sender = text(3)
            let body = text(1)
            let fromMe = sqlite3_column_int(stmt, 5) != 0
            result.append(AppNotification(
                id: "message-\(guid)",
                appID: appID,
                title: groupName.isEmpty ? sender : groupName,
                body: groupName.isEmpty || fromMe ? body : "\(sender): \(body)",
                date: Date(timeIntervalSinceReferenceDate: Double(sqlite3_column_int64(stmt, 2)) / 1_000_000_000),
                isFromUser: fromMe
            ))
        }
        return result
    }
}
