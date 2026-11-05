import Foundation
import SQLite3
import Testing
@testable import GleanerCore

@Suite("MessagesSource")
struct MessagesSourceTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func makeDatabase(at url: URL) {
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        defer { sqlite3_close(db) }
        func ns(_ seconds: Double) -> Int64 { Int64((base.timeIntervalSinceReferenceDate + seconds) * 1_000_000_000) }
        let sql = """
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, date INTEGER, is_from_me INTEGER,
                handle_id INTEGER, associated_message_type INTEGER DEFAULT 0);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, display_name TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            INSERT INTO handle VALUES (1, '106900'), (2, '+8613800000000');
            INSERT INTO chat VALUES (1, ''), (2, '家人群');
            INSERT INTO message VALUES (1, 'old', '旧消息', \(ns(-60)), 0, 1, 0);
            INSERT INTO message VALUES (2, 'code', '【某某云】您的验证码为 482913', \(ns(10)), 0, 1, 0);
            INSERT INTO message VALUES (3, 'mine', '我发的', \(ns(20)), 1, 2, 0);
            INSERT INTO message VALUES (4, 'tap', '喜欢', \(ns(30)), 0, 2, 2000);
            INSERT INTO message VALUES (5, 'group', '晚上回家吃饭吗', \(ns(40)), 0, 2, 0);
            INSERT INTO chat_message_join VALUES (1, 2), (2, 5);
            """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @Test("reads received texts after a cutoff, naming group chats")
    func reads() throws {
        let url = temporaryDirectory().appendingPathComponent("chat.db")
        makeDatabase(at: url)
        let all = try MessagesSource.read(databaseAt: url, after: base)
        #expect(all.first { $0.id == "message-mine" }?.isFromUser == true)
        let notes = all.filter { !$0.isFromUser }
        #expect(notes.map(\.id) == ["message-code", "message-group"])
        #expect(notes[0].title == "106900" && notes[0].body.contains("482913"))
        #expect(notes[1].title == "家人群" && notes[1].body == "+8613800000000: 晚上回家吃饭吗")
        #expect(abs(notes[0].date.timeIntervalSince(base.addingTimeInterval(10))) < 0.001)
    }

    @Test("returns nothing when Messages has never been used")
    func missing() throws {
        #expect(try MessagesSource(directory: temporaryDirectory()).fetch(after: base).isEmpty)
    }

    @Test("an SMS seen both as a notification and in Messages is kept once")
    func deduplicatesAgainstNotifications() throws {
        let notification = FakeSource()
        notification.add([AppNotification(id: "n1", appID: "com.apple.mobilesms", title: "某某云",
                                          body: "您的验证码为 482913", date: base.addingTimeInterval(11))])
        let messages = FakeSource()
        messages.add([
            AppNotification(id: "m1", appID: MessagesSource.appID, title: "106900", body: "您的验证码为 482913",
                            date: base.addingTimeInterval(10)),
            AppNotification(id: "m2", appID: MessagesSource.appID, title: "106900", body: "好的",
                            date: base.addingTimeInterval(12)),
        ])
        let ids = try CompositeNotificationSource([notification, messages]).fetch(after: base).map(\.id)
        #expect(ids == ["n1", "m2"])
    }
}

@Suite("WeChat files")
struct WeChatFileTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("finds new files in this month's folder of every account")
    func findsFiles() throws {
        let root = temporaryDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let folder = root.appendingPathComponent("wxid_test/msg/file/\(formatter.string(from: Date()))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("报价单.xlsx"))
        try Data().write(to: folder.appendingPathComponent("empty.tmp"))

        let notes = try WeChatFileSource(root: root).fetch(after: Date().addingTimeInterval(-60))
        #expect(notes.map(\.body) == ["报价单.xlsx"])
        #expect(notes.first?.attachmentPath?.hasSuffix("报价单.xlsx") == true)
        #expect(try WeChatFileSource(root: root).fetch(after: Date().addingTimeInterval(60)).isEmpty)
    }

    @Test("turns a file into an item attributed to the chat that mentioned it")
    func attachmentItems() {
        let file = AppNotification(id: "f", appID: WeChatFileSource.appID, title: "", body: "报价单.xlsx",
                                   date: date, attachmentPath: "/tmp/报价单.xlsx")
        let chat = AppNotification(id: "c", appID: WeChatFileSource.appID, title: "王总",
                                   body: "[文件] 报价单.xlsx", date: date.addingTimeInterval(-5))
        let item = AttachmentRule.items(in: [chat, file]).first
        #expect(item?.summary == "收到文件 报价单.xlsx")
        #expect(item?.kind == .notice && item?.sourceTitle == "王总")
        #expect(item?.attachmentPath == "/tmp/报价单.xlsx" && item?.sourceIDs == ["f", "c"])
        #expect(AttachmentRule.items(in: [chat]).isEmpty)
    }

    @Test("files never reach the model")
    func pipelineSkipsModelForFiles() async throws {
        let source = FakeSource()
        source.add([AppNotification(id: "f", appID: WeChatFileSource.appID, title: "", body: "合同.pdf",
                                    date: date.addingTimeInterval(1), attachmentPath: "/tmp/合同.pdf")])
        let provider = StubProvider(always: #"{"actions":[]}"#)
        actor Items { var all: [ActionItem] = []; func add(_ e: PipelineEvent) { if case .extracted(let i, _) = e { all += i } } }
        let items = Items()
        try await NotificationPipeline(source: source, stateStore: nil, now: date)
            .run(extractor: ActionExtractor(provider: provider)) { await items.add($0) }
        #expect(await items.all.map(\.summary) == ["收到文件 合同.pdf"])
        #expect(provider.receivedRequests.isEmpty)
    }
}

@Suite("Focus status")
struct FocusStatusTests {
    let configurations = Data("""
    {"data":[{"modeConfigurations":{
      "com.apple.focus.work":{"mode":{"name":"工作"}},
      "com.apple.donotdisturb.mode.default":{"mode":{"name":"Do Not Disturb"}}}}]}
    """.utf8)

    func assertions(mode: String?, invalidated: Bool = false, requestAt: Double? = nil) -> Data {
        let record = mode.map {
            #"{"assertionUUID":"A","assertionStartDateTimestamp":100.5,"assertionDetails":{"assertionDetailsModeIdentifier":"\#($0)"}}"#
        } ?? ""
        let invalidation = invalidated ? #"{"invalidationAssertion":{"assertionUUID":"A"}}"# : ""
        let request = requestAt.map {
            #"{"invalidationRequestDateTimestamp":\#($0),"invalidationRequestPredicate":{"invalidationPredicateType":"any"}}"#
        } ?? ""
        return Data(#"{"data":[{"storeAssertionRecords":[\#(record)],"storeInvalidationRecords":[\#(invalidation)],"storeInvalidationRequestRecords":[\#(request)]}]}"#.utf8)
    }

    @Test("names the active focus, localizing built-in modes")
    func active() {
        #expect(FocusStatus.activeMode(assertions: assertions(mode: "com.apple.focus.work"), configurations: configurations) == "工作")
        #expect(FocusStatus.activeMode(assertions: assertions(mode: "com.apple.donotdisturb.mode.default"),
                                       configurations: configurations) == "勿扰模式")
    }

    @Test("reports nothing when no focus is on or it was turned off")
    func inactive() {
        #expect(FocusStatus.activeMode(assertions: assertions(mode: nil), configurations: configurations) == nil)
        #expect(FocusStatus.activeMode(assertions: assertions(mode: "com.apple.focus.work", invalidated: true),
                                       configurations: configurations) == nil)
    }

    @Test("an assertion ended by a later or simultaneous request is not active")
    func endedByRequest() {
        let work = "com.apple.focus.work"
        #expect(FocusStatus.activeMode(assertions: assertions(mode: work, requestAt: 100.5), configurations: configurations) == nil)
        #expect(FocusStatus.activeMode(assertions: assertions(mode: work, requestAt: 200), configurations: configurations) == nil)
        #expect(FocusStatus.activeMode(assertions: assertions(mode: work, requestAt: 50), configurations: configurations) == "工作")
    }
}

@Suite("Group notices")
struct GroupNoticeTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let analyzer = MentionAnalyzer(userNames: ["小明"])

    func group(_ id: String, _ title: String, _ body: String, minutes: Double = 0) -> AppNotification {
        AppNotification(id: id, appID: "com.tencent.xinwechat", title: title, body: body,
                        date: date.addingTimeInterval(minutes * 60))
    }

    @Test("small talk", arguments: [
        ("老周: 哈哈哈 好的👌", false),
        ("张三: 好的收到", false),
        ("李四: 谢谢谢谢辛苦了", false),
        ("赵六: 1、本季度报表按什么口径统计？", true),
        ("王五: 晚上一起吃饭吗", true),
    ])
    func substance(body: String, expected: Bool) {
        #expect(GroupNoticeRule.isSubstantive(body) == expected)
    }

    @Test("one notice per group from substantive, uncovered, unaddressed messages")
    func notices() {
        let batch = [
            group("1", "资料群", "赵六: 1、本季度报表按什么口径统计？", minutes: 0),
            group("2", "资料群", "赵六: 答：按实际回款金额统计", minutes: 1),
            group("3", "饭搭子群", "老周: 哈哈哈 好的👌"),
            group("4", "项目群", "黄总: @小明 明早你讲下方案"),
            group("5", "王总", "报价单发我"),
            group("6", "读书群", "小李: 这周读到第三章了，大家进度如何", minutes: 2),
        ]
        let items = GroupNoticeRule.items(in: batch, analyzer: analyzer, covered: ["6"])
        #expect(items.map(\.sourceTitle) == ["资料群"])
        #expect(items.first?.summary == "答：按实际回款金额统计")
        #expect(items.first?.sourceIDs == ["1", "2"])
        #expect(items.first?.kind == .notice)
    }

    @Test("a conversation keeps one notice, updated to the latest")
    func noticeMerging() {
        let first = ActionItem(summary: "基金口径问题", priority: .low, kind: .notice, appID: "com.tencent.xinwechat",
                               sourceTitle: "资料群", sourceExcerpt: "a", notificationDate: date)
        let later = ActionItem(summary: "下周交材料", priority: .low, kind: .notice, appID: "com.tencent.xinwechat",
                               sourceTitle: "资料群", sourceExcerpt: "b", notificationDate: date.addingTimeInterval(600))
        let merged = [first].merging([later])
        #expect(merged.map(\.summary) == ["下周交材料"])
    }

    @Test("server errors are retried once")
    func retries() async throws {
        let ok = #"{"choices":[{"message":{"content":"ok"}}]}"#
        let http = MockHTTPClient(responses: [(500, "token repeat limit reached"), (200, ok)])
        let provider = OpenAICompatibleProvider(baseURL: "http://127.0.0.1:11434/v1", model: "m", apiKey: "", http: http)
        #expect(try await provider.complete(CompletionRequest(system: "s", user: "u")) == "ok")
        #expect(http.requests.count == 2)
    }
}

@Suite("Cross-run duplicates")
struct CrossRunDuplicateTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a message arriving through a second source in a later run is skipped")
    func laterRun() async throws {
        let source = FakeSource()
        source.add([AppNotification(id: "m1", appID: MessagesSource.appID, title: "106944021748251",
                                    body: "【上海信传量元】验证码 489147", date: start.addingTimeInterval(10))])
        let pipeline = NotificationPipeline(source: source, stateStore: nil, now: start)
        actor Log {
            var items: [ActionItem] = []
            var records: [ActivityRecord] = []
            func add(_ e: PipelineEvent) {
                if case .extracted(let i, _) = e { items += i }
                if case .activity(let r) = e { records += r }
            }
        }
        let log = Log()
        let extractor = ActionExtractor(provider: StubProvider(always: #"{"actions":[]}"#))
        try await pipeline.run(extractor: extractor) { await log.add($0) }

        source.add([AppNotification(id: "n1", appID: "com.apple.mobilesms", title: "106944021748251",
                                    body: "【上海信传量元】验证码 489147", date: start.addingTimeInterval(14))])
        try await pipeline.run(extractor: extractor) { await log.add($0) }

        #expect(await log.items.compactMap(\.verificationCode) == ["489147"])
        #expect(await log.records.first { $0.id == "n1" }?.outcome == .skipped(.duplicate))
    }

    @Test("the same code is never listed twice")
    func codeMerging() {
        func code(_ id: String) -> ActionItem {
            ActionItem(summary: "验证码 489147", kind: .code, appID: "com.apple.MobileSMS", sourceTitle: id,
                       sourceExcerpt: "", notificationDate: start)
        }
        #expect([code("a")].merging([code("b")]).count == 1)
    }
}
