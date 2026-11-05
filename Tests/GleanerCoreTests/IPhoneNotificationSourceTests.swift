import Foundation
import Testing
@testable import GleanerCore

/// Archived under the private class names macOS uses, so decoding exercises the
/// substitution path exactly as with real files.
@objc(GleanerTestsFakeEventBehavior)
private final class FakeEventBehavior: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let details: FakeEventDetails
    init(bundleID: String) { details = FakeEventDetails(bundleID: bundleID) }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(details, forKey: "eventDetails")
        coder.encode(3, forKey: "interruptionSuppression")
    }
}

@objc(GleanerTestsFakeEventDetails)
private final class FakeEventDetails: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let bundleID: String
    init(bundleID: String) { self.bundleID = bundleID }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(bundleID, forKey: "bundleIdentifier")
        coder.encode("some-thread", forKey: "threadIdentifier")
    }
}

@Suite("IPhoneNotificationSource", .serialized)
struct IPhoneNotificationSourceTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func record(id: String, bundleID: String?, title: String, body: String, at date: Date,
                otp: Bool = false, mentions: Bool = false) -> [String: Any] {
        var record: [String: Any] = [
            "AppNotificationIdentifier": id,
            "AppNotificationTitle": title,
            "AppNotificationMessage": body,
            "AppNotificationCreationDate": date,
            "ContainsOneTimePasscode": otp,
            "CommunicationContextMentionsCurrentUser": mentions,
            "SchemaVersion": 11,
        ]
        if let bundleID { record["EventBehavior"] = FakeEventBehavior(bundleID: bundleID) }
        return record
    }

    func archive(_ records: [[String: Any]]?,
                 behaviorClass: String = "DNDClientEventBehavior",
                 detailsClass: String = "DNDClientEventDetails") throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName(behaviorClass, for: FakeEventBehavior.self)
        archiver.setClassName(detailsClass, for: FakeEventDetails.self)
        archiver.encode(records.map { $0 as NSArray }, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Writes an app folder; `modified` stands in for when macOS last updated the file.
    func write(_ data: Data, app folder: String, in directory: URL, modified: Date) throws {
        let dir = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(IPhoneNotificationSource.fileName)
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    @Test("decodes forwarded notifications, recovering the bundle id from private objects")
    func decodes() throws {
        let data = try archive([
            record(id: "A", bundleID: "com.taobao.taobao4iphone", title: "雷克沙DDR5内存条", body: "32GB×2 内存套装", at: base),
            record(id: "B", bundleID: "com.google.Gmail", title: "Microsoft", body: "Your code: 482913", at: base, otp: true),
            record(id: "C", bundleID: nil, title: "t", body: "b", at: base, mentions: true),
        ])
        let notes = RemoteNotificationArchive.notifications(in: data)

        #expect(notes.map(\.id) == ["iphone-A", "iphone-B", "iphone-C"])
        #expect(notes.map(\.appID) == ["com.taobao.taobao4iphone", "com.google.Gmail", "iphone.unknown"])
        #expect(notes[0].title == "雷克沙DDR5内存条" && notes[0].body == "32GB×2 内存套装")
        #expect(notes.allSatisfy { $0.origin == .iPhone && $0.date == base })
        #expect(notes[1].isOneTimePasscode && !notes[0].isOneTimePasscode)
        #expect(notes[2].mentionsUser)
    }

    @Test("never instantiates archived classes that exist in the process but are not allowed")
    func substitutesLoadedClasses() throws {
        // In the app, the Do Not Disturb classes are loaded. Simulate that with classes this
        // test process certainly has, which secure decoding must not instantiate.
        let data = try archive([record(id: "A", bundleID: "com.sina.weibo", title: "微博", body: "x", at: base)],
                               behaviorClass: "NSProcessInfo", detailsClass: "NSBundle")
        #expect(RemoteNotificationArchive.classNames(in: data).isSuperset(of: ["NSProcessInfo", "NSBundle"]))
        #expect(RemoteNotificationArchive.notifications(in: data).map(\.appID) == ["com.sina.weibo"])
    }

    @Test("treats an empty archive as no notifications and garbage as unreadable")
    func emptyAndInvalid() throws {
        #expect(RemoteNotificationArchive.notifications(in: try archive(nil)).isEmpty)
        #expect(RemoteNotificationArchive.notifications(in: Data("not a plist".utf8)).isEmpty)
    }

    @Test("reads every app folder, newest-first cutoff, sorted by date")
    func fetchesFromFolders() throws {
        let dir = temporaryDirectory()
        try write(archive([
            record(id: "old", bundleID: "com.sina.weibo", title: "旧", body: "x", at: base.addingTimeInterval(-60)),
            record(id: "w", bundleID: "com.sina.weibo", title: "微博", body: "y", at: base.addingTimeInterval(20)),
        ]), app: "AAAA", in: dir, modified: base.addingTimeInterval(20))
        try write(archive([
            record(id: "m", bundleID: "com.meituan.imeituan", title: "美团", body: "z", at: base.addingTimeInterval(10)),
        ]), app: "BBBB", in: dir, modified: base.addingTimeInterval(10))
        try write(archive(nil), app: "CCCC", in: dir, modified: base.addingTimeInterval(30))

        let source = IPhoneNotificationSource(directory: dir)
        #expect(try source.fetch(after: base).map(\.id) == ["iphone-m", "iphone-w"])
        #expect(source.changeToken() == base.addingTimeInterval(30))
    }

    @Test("skips app folders not written since the cutoff")
    func skipsUnchangedFolders() throws {
        let dir = temporaryDirectory()
        // Not rewritten since `base`, so it is not even opened.
        try write(archive([record(id: "x", bundleID: "com.sina.weibo", title: "t", body: "b", at: base.addingTimeInterval(5))]),
                  app: "AAAA", in: dir, modified: base)
        #expect(try IPhoneNotificationSource(directory: dir).fetch(after: base).isEmpty)
    }

    @Test("returns nothing when the feature is not in use")
    func missingDirectory() throws {
        let source = IPhoneNotificationSource(directory: temporaryDirectory().appendingPathComponent("nope"))
        #expect(try source.fetch(after: base).isEmpty)
        #expect(source.changeToken() == nil)
    }
}

@Suite("CompositeNotificationSource")
struct CompositeNotificationSourceTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func iPhoneNote(_ id: String, body: String, at date: Date) -> AppNotification {
        AppNotification(id: id, appID: "com.tencent.xinwechat", title: "群聊", body: body, date: date, origin: .iPhone)
    }

    @Test("merges sources in date order")
    func merges() throws {
        let mac = FakeSource()
        mac.add([note("m1", body: "Mac 消息", at: base.addingTimeInterval(20))])
        let phone = FakeSource()
        phone.add([iPhoneNote("p1", body: "手机消息", at: base.addingTimeInterval(10))])

        let combined = CompositeNotificationSource([mac, phone])
        #expect(try combined.fetch(after: base).map(\.id) == ["p1", "m1"])
        #expect(combined.changeToken() != nil)
    }

    @Test("keeps one copy of a message delivered to both devices")
    func dropsCrossDeviceDuplicates() throws {
        let mac = FakeSource()
        mac.add([note("m1", body: "张三: 方案呢？", at: base.addingTimeInterval(10))])
        let phone = FakeSource()
        phone.add([
            iPhoneNote("p1", body: "张三: 方案呢？", at: base.addingTimeInterval(13)),
            iPhoneNote("p2", body: "张三: 方案呢？", at: base.addingTimeInterval(900)),
        ])

        let ids = try CompositeNotificationSource([mac, phone]).fetch(after: base).map(\.id)
        #expect(ids == ["m1", "p2"])
    }

    @Test("reports missing permission even if another source works")
    func surfacesAccessDenied() {
        let phone = FakeSource()
        phone.add([iPhoneNote("p1", body: "x", at: base.addingTimeInterval(1))])
        #expect(throws: NotificationSourceError.accessDenied) {
            try CompositeNotificationSource([DeniedSource(), phone]).fetch(after: base)
        }
    }

    @Test("tolerates other failures while one source works")
    func toleratesPartialFailure() throws {
        struct Broken: NotificationSource {
            func changeToken() -> Date? { nil }
            func fetch(after date: Date) throws -> [AppNotification] { throw NotificationSourceError.unreadable("x") }
        }
        let mac = FakeSource()
        mac.add([note("m1", body: "x", at: base.addingTimeInterval(1))])
        #expect(try CompositeNotificationSource([Broken(), mac]).fetch(after: base).map(\.id) == ["m1"])
        #expect(throws: NotificationSourceError.unreadable("x")) {
            try CompositeNotificationSource([Broken()]).fetch(after: base)
        }
    }
}

@Suite("System hints")
struct SystemHintTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a system-flagged passcode is detected without keywords")
    func flaggedPasscode() {
        let flagged = AppNotification(id: "1", appID: "com.google.Gmail", title: "Microsoft",
                                      body: "482913 用于验证你的账户", date: date, isOneTimePasscode: true)
        let unflagged = AppNotification(id: "2", appID: "com.google.Gmail", title: "Microsoft",
                                        body: "订单 482913 已发货", date: date)
        #expect(VerificationCodeDetector.item(for: flagged)?.verificationCode == "482913")
        #expect(VerificationCodeDetector.item(for: flagged)?.origin == .mac)
        #expect(VerificationCodeDetector.item(for: unflagged) == nil)
    }

    @Test("a system-detected mention counts as addressing the user")
    func systemMention() {
        let note = AppNotification(id: "1", appID: "com.tencent.xinwechat", title: "项目群",
                                   body: "黄总: @李四 你和小明一起看下", date: date, mentionsUser: true)
        #expect(MentionAnalyzer(userNames: ["小明"]).addressee(of: note) == .user)
    }

    @Test("items remember which device they came from")
    func itemOrigin() throws {
        let batch = [AppNotification(id: "1", appID: "com.sina.weibo", title: "微博", body: "x", date: date, origin: .iPhone)]
        let item = try #require(ActionExtractor.makeItem(from: .init(sources: [1], summary: "看私信"), batch: batch))
        #expect(item.origin == .iPhone)
    }
}
