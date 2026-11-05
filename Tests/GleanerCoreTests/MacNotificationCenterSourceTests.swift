import Foundation
import SQLite3
import Testing
@testable import GleanerCore

/// Exercises the database reader against a synthetic database with the same layout
/// as macOS's notification center, so no Full Disk Access is needed.
@Suite("MacNotificationCenterSource")
struct MacNotificationCenterSourceTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func makeDatabase(at url: URL, records: [(uuid: String, app: String, plist: [String: Any]?, date: Date)]) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
            CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB,
                request_date REAL, request_last_date REAL, delivered_date REAL, presented Bool,
                style INTEGER, snooze_fire_date REAL);
            """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var appIDs: [String: Int64] = [:]
        for record in records {
            if appIDs[record.app] == nil {
                appIDs[record.app] = Int64(appIDs.count + 1)
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, "INSERT INTO app VALUES (?, ?)", -1, &stmt, nil)
                sqlite3_bind_int64(stmt, 1, appIDs[record.app]!)
                sqlite3_bind_text(stmt, 2, record.app, -1, transient)
                #expect(sqlite3_step(stmt) == SQLITE_DONE)
                sqlite3_finalize(stmt)
            }

            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO record (app_id, uuid, data, delivered_date) VALUES (?, ?, ?, ?)", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, appIDs[record.app]!)
            let uuid = Data(record.uuid.utf8)
            _ = uuid.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), transient) }
            if let plist = record.plist {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32($0.count), transient) }
            }
            sqlite3_bind_double(stmt, 4, record.date.timeIntervalSinceReferenceDate)
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    @Test("reads title, subtitle, body, app and date of records after a cutoff")
    func readsRecords() throws {
        let url = temporaryDirectory().appendingPathComponent("db")
        try makeDatabase(at: url, records: [
            ("u1", "com.tencent.xinwechat", ["req": ["titl": "旧消息", "body": "早"]], base),
            ("u2", "com.tencent.xinwechat", ["req": ["titl": "项目群", "subt": "张三", "body": "张三: 方案呢？"]],
             base.addingTimeInterval(60)),
            ("u3", "com.tencent.weworkmac", ["req": ["titl": "打卡", "body": "打卡异常"]], base.addingTimeInterval(120)),
            ("u4", "com.example.broken", nil, base.addingTimeInterval(180)),
        ])

        let notes = try MacNotificationCenterSource.read(databaseAt: url, after: base)

        #expect(notes.map(\.title) == ["项目群", "打卡", ""])
        let first = try #require(notes.first)
        #expect(first.appID == "com.tencent.xinwechat")
        #expect(first.subtitle == "张三")
        #expect(first.body == "张三: 方案呢？")
        #expect(first.date == base.addingTimeInterval(60))
        #expect(first.id == Data("u2".utf8).map { String(format: "%02X", $0) }.joined())
        #expect(notes.last?.hasContent == false)
    }

    @Test("copies the database before reading and reports a missing directory as access denied")
    func fetchFromDirectory() throws {
        let dir = temporaryDirectory()
        try makeDatabase(at: dir.appendingPathComponent("db"), records: [
            ("u1", "com.example.app", ["req": ["titl": "t", "body": "b"]], base.addingTimeInterval(1)),
        ])
        let source = MacNotificationCenterSource(directory: dir)

        #expect(try source.fetch(after: base).map(\.body) == ["b"])
        #expect(source.changeToken() != nil)

        let missing = MacNotificationCenterSource(directory: dir.appendingPathComponent("nope"))
        #expect(throws: NotificationSourceError.accessDenied) { try missing.fetch(after: base) }
    }
}
