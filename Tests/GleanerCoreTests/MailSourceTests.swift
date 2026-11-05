import Foundation
import SQLite3
import Testing
@testable import GleanerCore

@Suite struct MailMessageTextTests {
    private func emlx(_ message: String) -> Data {
        let body = Data(message.utf8)
        return Data("\(body.count)\n".utf8) + body + Data("<?xml version=\"1.0\"?><plist></plist>".utf8)
    }

    @Test func readsPlainText() {
        let message = "From: a@b.c\r\nSubject: hi\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n您的验证码是 482913，\r\n5 分钟内有效。\r\n"
        #expect(MailMessageText.text(fromEMLX: emlx(message)) == "您的验证码是 482913，\n5 分钟内有效。")
    }

    @Test func decodesQuotedPrintableGBK() {
        // "验证码" in GBK, quoted-printable.
        let message = "Content-Type: text/plain; charset=\"gb2312\"\nContent-Transfer-Encoding: quoted-printable\n\n=D1=E9=D6=A4=C2=EB 1234=\n56\n"
        #expect(MailMessageText.text(fromMessage: Data(message.utf8)) == "验证码 123456")
    }

    @Test func prefersPlainPartAndFallsBackToHTML() {
        let html = Data("<html><style>p{}</style><body><p>报价单&nbsp;请查收</p><br>谢谢&#65281;</body></html>".utf8).base64EncodedString()
        let multipart = """
        Content-Type: multipart/alternative; boundary="XYZ"

        --XYZ
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        \(html)
        --XYZ--
        """
        #expect(MailMessageText.text(fromMessage: Data(multipart.utf8)) == "报价单 请查收\n\n谢谢！")

        let both = """
        Content-Type: multipart/mixed; boundary=outer

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=utf-8

        纯文本正文
        --inner
        Content-Type: text/html; charset=utf-8

        <p>HTML 正文</p>
        --inner--
        --outer
        Content-Type: application/pdf; name=a.pdf
        Content-Transfer-Encoding: base64

        JVBERi0=
        --outer--
        """
        #expect(MailMessageText.text(fromMessage: Data(both.utf8)) == "纯文本正文")
    }

    @Test func limitsLength() {
        let message = "Content-Type: text/plain\n\n" + String(repeating: "长", count: 50)
        #expect(MailMessageText.text(fromMessage: Data(message.utf8), limit: 10)?.count == 10)
    }
}

@Suite struct MailSourceTests {
    @Test func recognizesInboxes() {
        #expect(MailSource.isInbox("imap://ACCT/INBOX"))
        #expect(MailSource.isInbox("ews://ACCT/%E6%94%B6%E4%BB%B6%E7%AE%B1"))  // 收件箱
        #expect(!MailSource.isInbox("ews://ACCT/%E5%9E%83%E5%9C%BE%E9%82%AE%E4%BB%B6"))  // 垃圾邮件
        #expect(!MailSource.isInbox("imap://ACCT/Sent%20Messages"))
    }

    @Test func partitionsByThousands() {
        #expect(MailSource.partition(for: 999) == "")
        #expect(MailSource.partition(for: 3087) == "3")
        #expect(MailSource.partition(for: 12_345) == "2/1")
        #expect(MailSource.partition(for: 1_234_567) == "4/3/2/1")
    }

    /// A Mail library with one account, an inbox and a junk folder.
    private func makeLibrary() throws -> (root: URL, index: URL, version: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-test-\(UUID().uuidString)")
        let version = root.appendingPathComponent("V10")
        let data = version.appendingPathComponent("MailData")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let index = data.appendingPathComponent("Envelope Index")
        var db: OpaquePointer?
        sqlite3_open(index.path, &db)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, subject INTEGER, summary INTEGER,
            date_received INTEGER, mailbox INTEGER, deleted INTEGER DEFAULT 0);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCT/INBOX'), (2, 'imap://ACCT/Junk');
        INSERT INTO addresses VALUES (1, 'noreply@example.com', '某某云');
        INSERT INTO subjects VALUES (1, '登录验证码'), (2, '垃圾');
        """
        sqlite3_exec(db, schema, nil, nil, nil)
        return (root, index, version)
    }

    private func insert(_ index: URL, rowID: Int, mailbox: Int, received: Date) {
        var db: OpaquePointer?
        sqlite3_open(index.path, &db)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "INSERT INTO messages VALUES (\(rowID), 1, \(mailbox), NULL, \(Int(received.timeIntervalSince1970)), \(mailbox), 0)",
                     nil, nil, nil)
    }

    @Test func readsInboxMailWithBody() throws {
        let (root, index, version) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        insert(index, rowID: 1500, mailbox: 1, received: now.addingTimeInterval(-60))
        insert(index, rowID: 1501, mailbox: 2, received: now.addingTimeInterval(-60))
        let messages = version.appendingPathComponent("ACCT/INBOX.mbox/STORE/Data/1/Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let mail = "Content-Type: text/plain; charset=utf-8\n\n您的验证码为 482913，5 分钟内有效。\n"
        try (Data("\(mail.utf8.count)\n".utf8) + Data(mail.utf8)).write(to: messages.appendingPathComponent("1500.emlx"))

        let source = MailSource(directory: root)
        let notes = try source.fetch(after: now.addingTimeInterval(-3600))
        #expect(notes.map(\.id) == ["mail-1500"])
        #expect(notes.first?.title == "某某云")
        #expect(notes.first?.subtitle == "登录验证码")
        #expect(notes.first?.body.contains("482913") == true)
        #expect(VerificationCodeDetector.item(for: notes[0])?.verificationCode == "482913")
    }

    @Test func lateMailIsDatedWhenFirstSeen() throws {
        let (root, index, _) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        insert(index, rowID: 10, mailbox: 1, received: now.addingTimeInterval(-30))
        let source = MailSource(directory: root)
        _ = try source.fetch(after: now.addingTimeInterval(-60))
        // Mail downloads a message received hours ago, after the cursor moved past that time.
        insert(index, rowID: 11, mailbox: 1, received: now.addingTimeInterval(-3 * 3600))
        let cursor = now.addingTimeInterval(-10)
        let late = try source.fetch(after: cursor)
        #expect(late.map(\.id) == ["mail-11"])
        #expect(late[0].date > cursor)
        // Asking again returns the same date, so a retried batch isn't lost or duplicated.
        let again = try source.fetch(after: cursor)
        #expect(again.first?.date == late.first?.date)
    }

    @Test func historyOfANewAccountIsNotNewMail() throws {
        let (root, index, _) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        insert(index, rowID: 10, mailbox: 1, received: now.addingTimeInterval(-30))
        let source = MailSource(directory: root)
        _ = try source.fetch(after: now.addingTimeInterval(-60))
        // An account is added; Mail downloads its inbox going back weeks.
        for row in 11...20 { insert(index, rowID: row, mailbox: 1, received: now.addingTimeInterval(-Double(row) * 86_400)) }
        insert(index, rowID: 21, mailbox: 1, received: now.addingTimeInterval(-5))  // and one genuinely new message
        let fetched = try source.fetch(after: now.addingTimeInterval(-10))
        #expect(fetched.map(\.id) == ["mail-21"])
    }
}
