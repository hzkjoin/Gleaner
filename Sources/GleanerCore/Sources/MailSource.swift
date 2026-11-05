import Foundation
import SQLite3

/// Reads new mail in the inboxes of Apple Mail, from its local index and message files.
///
/// Covers every account set up in Mail, whether or not Mail shows a notification. Requires
/// Full Disk Access; the index is copied before reading, like the other databases.
///
/// Mail can download older messages late (after the Mac wakes, say), dated before mail that
/// was already processed. Rows added since the source started and received within
/// `lateWindow` are therefore dated no earlier than when they were first seen, so the pipeline
/// still treats them as new. Older rows that appear (a newly added account bringing its whole
/// history) are not new mail and are left alone.
///
/// Mail adds a message to its index before writing the message file. A message whose text
/// isn't there yet is held back for up to `bodyWait` (a code in the body matters more than a
/// few seconds), then dated when it is finally handed over.
public final class MailSource: NotificationSource, @unchecked Sendable {
    public static let appID = "com.apple.mail"
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")

    /// The Mail library (`~/Library/Mail`); the current `V*` folder is found inside.
    public let directory: URL
    /// Characters of body text kept per message.
    public var bodyLimit: Int
    /// How old a late-downloaded message may be and still count as new.
    public var lateWindow: TimeInterval = 24 * 3600
    /// How long to wait for a message's text to be written.
    public var bodyWait: TimeInterval = 120

    private let lock = NSLock()
    /// The highest row present when the source first read the index.
    private var baselineRowID: Int64?
    /// When rows added after the baseline were first seen.
    private var firstSeen: [Int64: Date] = [:]
    /// Rows held back until their text arrives, and since when.
    private var waiting: [Int64: Date] = [:]
    /// When rows that were held back were handed over, which dates them.
    private var released: [Int64: Date] = [:]

    public init(directory: URL = MailSource.defaultDirectory, bodyLimit: Int = 800) {
        self.directory = directory
        self.bodyLimit = bodyLimit
    }

    /// The newest `V<n>` folder holding `MailData/Envelope Index`.
    var versionDirectory: URL? {
        let versions = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("V") && Int($0.lastPathComponent.dropFirst()) != nil }
            .sorted { Int($0.lastPathComponent.dropFirst())! > Int($1.lastPathComponent.dropFirst())! }
        return versions.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("MailData/Envelope Index").path) }
    }

    public func changeToken() -> Date? {
        // Mail writes message files without touching the index; keep looking while waiting for one.
        if lock.withLock({ !waiting.isEmpty }) { return Date() }
        guard let data = versionDirectory?.appendingPathComponent("MailData") else { return nil }
        return ["Envelope Index", "Envelope Index-wal"].compactMap { name -> Date? in
            (try? FileManager.default.attributesOfItem(atPath: data.appendingPathComponent(name).path))?[.modificationDate] as? Date
        }.max()
    }

    public func fetch(after date: Date) throws -> [AppNotification] {
        guard let version = versionDirectory else { return [] }  // Mail never set up.
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("gleaner-mail-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        let data = version.appendingPathComponent("MailData")
        do {
            try fm.copyItem(at: data.appendingPathComponent("Envelope Index"), to: workDir.appendingPathComponent("index"))
        } catch {
            // Not `accessDenied`: that would flag the whole app as unauthorized over one source.
            throw NotificationSourceError.unreadable("cannot copy Mail index")
        }
        try? fm.copyItem(at: data.appendingPathComponent("Envelope Index-wal"), to: workDir.appendingPathComponent("index-wal"))

        let rows = try Self.read(databaseAt: workDir.appendingPathComponent("index"), after: date,
                                 newerThan: lock.withLock { baselineRowID }, lateSince: Date().addingTimeInterval(-lateWindow))
        let now = Date()
        return lock.withLock {
            // Everything present now is judged by its own date; only rows added later are dated by first sight.
            if baselineRowID == nil { baselineRowID = Self.maxRowID(in: workDir.appendingPathComponent("index")) }
            let baseline = baselineRowID ?? 0
            var result: [AppNotification] = []
            for row in rows {
                var effective = row.received
                if row.rowID > baseline {
                    let seen = firstSeen[row.rowID] ?? now
                    firstSeen[row.rowID] = seen
                    effective = max(row.received, seen)
                }
                let body = Self.bodyText(for: row, in: version, limit: bodyLimit)
                if body == nil && row.summary.isEmpty && released[row.rowID] == nil {
                    let since = waiting[row.rowID] ?? now
                    if now.timeIntervalSince(since) < bodyWait {
                        waiting[row.rowID] = since
                        continue
                    }
                }
                if waiting.removeValue(forKey: row.rowID) != nil { released[row.rowID] = now }
                if let handedOver = released[row.rowID] { effective = max(effective, handedOver) }
                guard effective > date else { continue }
                result.append(row.notification(date: effective, body: body))
            }
            // Forget rows that are well behind.
            let horizon = now.addingTimeInterval(-2 * 86_400)
            firstSeen = firstSeen.filter { $0.value > horizon }
            released = released.filter { $0.value > horizon }
            waiting = waiting.filter { $0.value > horizon }
            return result.sorted { $0.date < $1.date }
        }
    }

    // MARK: - Index

    struct Row: Equatable {
        var rowID: Int64
        var sender: String
        var address: String
        var subject: String
        var summary: String
        var received: Date
        var mailboxURL: String

        func notification(date: Date, body: String?) -> AppNotification {
            let text = [body ?? summary].first { !$0.isEmpty } ?? ""
            return AppNotification(id: "mail-\(rowID)", appID: MailSource.appID, title: sender.isEmpty ? address : sender,
                                   subtitle: subject, body: text.isEmpty ? subject : "\(subject)\n\(text)", date: date)
        }
    }

    /// Whether a mailbox URL is an inbox (`imap://…/INBOX`, `ews://…/收件箱`).
    static func isInbox(_ url: String) -> Bool {
        let decoded = url.removingPercentEncoding ?? url
        guard let last = decoded.split(separator: "/").last?.lowercased() else { return false }
        return last == "inbox" || last == "收件箱"
    }

    static func read(databaseAt url: URL, after date: Date, newerThan baseline: Int64?, lateSince: Date) throws -> [Row] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw NotificationSourceError.unreadable("cannot open Mail index")
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT m.ROWID, a.comment, a.address, s.subject, sm.summary, m.date_received, b.url
            FROM messages m
            JOIN mailboxes b ON b.ROWID = m.mailbox
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN summaries sm ON sm.ROWID = m.summary
            WHERE m.deleted = 0 AND (m.date_received > ? OR (m.ROWID > ? AND m.date_received > ?))
            ORDER BY m.ROWID ASC
            LIMIT 500
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NotificationSourceError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(date.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, baseline ?? Int64.max)
        sqlite3_bind_int64(stmt, 3, Int64(lateSince.timeIntervalSince1970))

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
            }
            let mailbox = text(6)
            guard isInbox(mailbox) else { continue }
            rows.append(Row(rowID: sqlite3_column_int64(stmt, 0), sender: text(1), address: text(2), subject: text(3),
                            summary: text(4), received: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5))),
                            mailboxURL: mailbox))
        }
        return rows
    }

    static func maxRowID(in url: URL) -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT max(ROWID) FROM messages", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    // MARK: - Message files

    /// `V10/<account>/<mailbox>.mbox/<store>/Data/<partition>/Messages/<row>.emlx`, where the
    /// partition is the digits of `row / 1000`, last digit first (none below 1000).
    static func partition(for rowID: Int64) -> String {
        let thousands = rowID / 1000
        guard thousands > 0 else { return "" }
        return String(String(thousands).reversed()).map(String.init).joined(separator: "/")
    }

    static func messageFile(for row: Row, in version: URL) -> URL? {
        let decoded = row.mailboxURL.removingPercentEncoding ?? row.mailboxURL
        guard let schemeEnd = decoded.range(of: "://") else { return nil }
        let path = decoded[schemeEnd.upperBound...].split(separator: "/").map(String.init)
        guard path.count >= 2 else { return nil }
        let account = path[0]
        let mailbox = path.dropFirst().map { $0 + ".mbox" }.joined(separator: "/")
        let mailboxDir = version.appendingPathComponent(account).appendingPathComponent(mailbox)
        let stores = (try? FileManager.default.contentsOfDirectory(at: mailboxDir, includingPropertiesForKeys: nil)) ?? []
        let partition = partition(for: row.rowID)
        for store in stores {
            var messages = store.appendingPathComponent("Data")
            if !partition.isEmpty { messages.appendPathComponent(partition) }
            messages.appendPathComponent("Messages")
            for name in ["\(row.rowID).emlx", "\(row.rowID).partial.emlx"] {
                let file = messages.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { return file }
            }
        }
        return nil
    }

    static func bodyText(for row: Row, in version: URL, limit: Int) -> String? {
        guard let file = messageFile(for: row, in: version), let data = try? Data(contentsOf: file) else { return nil }
        return MailMessageText.text(fromEMLX: data, limit: limit)
    }
}
