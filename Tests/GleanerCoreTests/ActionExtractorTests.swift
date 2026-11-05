import Foundation
import Testing
@testable import GleanerCore

@Suite("ActionExtractor")
struct ActionExtractorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("parses plain JSON")
    func parsesPlainJSON() throws {
        let actions = try ActionExtractor.parse(#"{"actions":[{"sources":[1],"summary":"回复报价","due":"今天","priority":"high"}]}"#)
        #expect(actions == [ExtractedAction(sources: [1], summary: "回复报价", due: "今天", priority: "high")])
    }

    @Test("ignores think blocks and code fences")
    func parsesWrappedJSON() throws {
        let output = """
        <think>
        用户需要处理 {这件事}
        </think>
        ```json
        {"actions":[{"sources":[2],"summary":"处理打卡异常","due":"","priority":"medium"}]}
        ```
        """
        let actions = try ActionExtractor.parse(output)
        #expect(actions.map(\.summary) == ["处理打卡异常"])
    }

    @Test("parses an empty action list")
    func parsesEmpty() throws {
        #expect(try ActionExtractor.parse(#"{"actions":[]}"#).isEmpty)
    }

    @Test("rejects output without JSON", arguments: ["", "没有需要处理的事", #"{"items":[]}"#])
    func rejectsInvalidOutput(_ output: String) {
        #expect(throws: LLMError.self) { try ActionExtractor.parse(output) }
    }

    @Test("drops actions whose sources are out of range or whose summary is blank")
    func validatesActions() {
        let batch = [note("a", body: "x", at: now)]
        #expect(ActionExtractor.makeItem(from: .init(sources: [0, 2], summary: "做事"), batch: batch) == nil)
        #expect(ActionExtractor.makeItem(from: .init(sources: [1], summary: "   "), batch: batch) == nil)
        #expect(ActionExtractor.makeItem(from: .init(sources: [1, 5], summary: "做事"), batch: batch) != nil)
    }

    @Test("attaches the latest source and normalizes priority")
    func buildsItem() throws {
        let batch = [
            note("a", title: "项目群", body: "明天交方案吗？", at: now),
            note("b", app: "com.example.mail", title: "王总", body: "@我 方案今天要", at: now.addingTimeInterval(60)),
        ]
        let item = try #require(ActionExtractor.makeItem(
            from: .init(sources: [1, 2], summary: " 提交方案 ", due: " 今天 ", priority: "HIGH"), batch: batch))
        #expect(item.summary == "提交方案")
        #expect(item.due == "今天")
        #expect(item.priority == .high)
        #expect(item.appID == "com.example.mail")
        #expect(item.sourceTitle == "王总")
        #expect(item.sourceExcerpt == "明天交方案吗？ / @我 方案今天要")

        let unknown = try #require(ActionExtractor.makeItem(from: .init(sources: [1], summary: "x", priority: "urgent"), batch: batch))
        #expect(unknown.priority == .medium)
    }

    @Test("builds a prompt with numbered notifications, app names and user names")
    func buildsPrompt() async throws {
        let provider = StubProvider(always: actionsJSON([([1], "处理打卡异常")]))
        let extractor = ActionExtractor(
            provider: provider,
            userNames: ["小明", "Ming"],
            appName: { $0 == "com.example.chat" ? "聊天" : $0 },
            now: { now }
        )
        let items = try await extractor.extract(from: [note("a", body: "打卡\n异常", at: now)])

        #expect(items.map(\.summary) == ["处理打卡异常"])
        let request = try #require(provider.receivedRequests.first)
        #expect(request.system.contains("小明、Ming"))
        #expect(request.user.contains("[1]"))
        #expect(request.user.contains("聊天 | 群聊 | 打卡 异常"))
        #expect(request.jsonSchema != nil)
    }

    @Test("does not call the model for an empty batch")
    func skipsEmptyBatch() async throws {
        let provider = StubProvider(always: "")
        let items = try await ActionExtractor(provider: provider).extract(from: [])
        #expect(items.isEmpty)
        #expect(provider.receivedRequests.isEmpty)
    }

    @Test("the output schema is valid JSON")
    func schemaIsValidJSON() {
        #expect(HTTPSupport.jsonObject(ExtractionPrompt.schema) is [String: Any])
    }
}

@Suite("ActionItem")
struct ActionItemTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("maps kind, falling back to task")
    func kinds() throws {
        let batch = [note("a", title: "王总", body: "报价单今天发我", at: date)]
        let notice = try #require(ActionExtractor.makeItem(from: .init(sources: [1], summary: "交周报", kind: "notice"), batch: batch))
        #expect(notice.kind == .notice)
        #expect(!notice.kind.acceptsReply)
        let unknown = try #require(ActionExtractor.makeItem(from: .init(sources: [1], summary: "x", kind: "other"), batch: batch))
        #expect(unknown.kind == .task)
    }

    @Test("extracts verification codes", arguments: [
        ("验证码 482913（某某云）", "482913"),
        ("验证码：AB12CD", "AB12CD"),
        ("Your code is 7731", "7731"),
    ])
    func verificationCode(summary: String, expected: String) {
        let item = ActionItem(summary: summary, kind: .code, appID: "a", sourceTitle: "", sourceExcerpt: "", notificationDate: date)
        #expect(item.verificationCode == expected)
    }

    @Test("has no verification code for other kinds or text without digits")
    func noVerificationCode() {
        let task = ActionItem(summary: "验证码 482913", kind: .task, appID: "a", sourceTitle: "", sourceExcerpt: "", notificationDate: date)
        #expect(task.verificationCode == nil)
        let letters = ActionItem(summary: "输入验证码 HELLO", kind: .code, appID: "a", sourceTitle: "", sourceExcerpt: "", notificationDate: date)
        #expect(letters.verificationCode == nil)
    }

    @Test("decodes items saved before kind and suggestedReply existed")
    func decodesLegacyItems() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","summary":"回复张三","due":"","priority":"medium","appID":"com.tencent.xinwechat",
          "sourceTitle":"项目群","sourceExcerpt":"张三: 在吗","notificationDate":"2026-11-04T09:00:00Z","createdAt":"2026-11-04T09:00:01Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([ActionItem].self, from: Data(legacy.utf8))
        #expect(items.first?.kind == .task)
        #expect(items.first?.suggestedReply == "")
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let item = ActionItem(summary: "回复", priority: .high, kind: .reply, suggestedReply: "好的",
                              appID: "a", sourceTitle: "t", sourceExcerpt: "e", notificationDate: date, createdAt: date)
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(ActionItem.self, from: data) == item)
    }
}

@Suite("VerificationCodeDetector")
struct VerificationCodeDetectorTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("finds codes in verification messages", arguments: [
        ("【某某云】您的验证码为 482913，5分钟内有效。", "482913"),
        ("【银行】尾号1234的账户，动态码 559201，请勿泄露", "559201"),
        ("Your verification code is 7731.", "7731"),
        ("校验码：AB12CD", "AB12CD"),
        ("Your OTP: 908172. Do not share it.", "908172"),
        ("Ant Bank 登录验证码\n你的一次性验证码是 2325，10 分钟内有效", "2325"),
    ])
    func finds(text: String, expected: String) {
        #expect(VerificationCodeDetector.code(in: text) == expected)
    }

    @Test("ignores messages that are not verification codes", arguments: [
        "订单 20261104 已发货",
        "会议改到 1530 开始",
        "请输入验证码",
        // A statement email: the number comes before the security footer that mentions OTP.
        "你的投资账户电子月结单已准备好。客服热线 2325 8888。" + String(repeating: "说明文字。", count: 20)
            + "We will never ask for your one-time password.",
        // The keyword far from any number.
        "验证码相关说明。" + String(repeating: "很长的正文。", count: 20) + "合同编号 A1234。",
        // Not the keyword "OTP".
        "Hotpot night 1234 tickets",
    ])
    func ignores(text: String) {
        #expect(VerificationCodeDetector.code(in: text) == nil)
    }

    @Test("builds a high-priority code item with the sender")
    func buildsItem() throws {
        let item = try #require(VerificationCodeDetector.items(in: [
            note("1", app: "com.apple.MobileSMS", title: "106900", body: "【某某云】您的验证码为 482913", at: date),
        ]).first)
        #expect(item.summary == "验证码 482913（某某云）")
        #expect(item.kind == .code)
        #expect(item.priority == .high)
        #expect(item.verificationCode == "482913")
    }

    @Test("adds codes the model missed and does not duplicate ones it found")
    func merges() {
        let detected = VerificationCodeDetector.items(in: [
            note("1", body: "验证码 111111", at: date),
            note("2", body: "验证码 222222", at: date),
        ])
        let fromModel = [
            ActionItem(summary: "输入验证码 111111", kind: .task, suggestedReply: "x",
                       appID: "a", sourceTitle: "", sourceExcerpt: "", notificationDate: date),
        ]
        let merged = ActionExtractor.merge(fromModel, detectedCodes: detected)
        #expect(merged.count == 2)
        #expect(merged[0].verificationCode == "111111" && merged[0].kind == .code && merged[0].suggestedReply.isEmpty)
        #expect(merged[1].verificationCode == "222222")
    }

    @Test("prefers the rule-based wording when the model leaves out the code")
    func prefersDetectedWording() {
        let detected = VerificationCodeDetector.items(in: [note("1", body: "【某某云】您的验证码为 482913", at: date)])
        let fromModel = [ActionItem(summary: "验证某某云账号安全", kind: .code, appID: "a", sourceTitle: "",
                                    sourceExcerpt: "【某某云】您的验证码为 482913", notificationDate: date)]
        let merged = ActionExtractor.merge(fromModel, detectedCodes: detected)
        #expect(merged.map(\.summary) == ["验证码 482913（某某云）"])
    }
}

@Suite struct CodeSplitTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ruleHandlesShortMessagesAndLeavesMailToTheModel() {
        let sms = note("1", app: "com.apple.MobileSMS", title: "106900", body: "【某某云】您的验证码为 482913", at: date)
        #expect(VerificationCodeDetector.item(for: sms)?.verificationCode == "482913")
        let mail = note("2", app: "com.apple.mail", title: "某某云", body: "您的验证码为 482913", at: date)
        #expect(VerificationCodeDetector.item(for: mail) == nil)
        let long = note("3", app: "com.example", title: "x", body: "验证码 482913 " + String(repeating: "很长的说明。", count: 60), at: date)
        #expect(VerificationCodeDetector.item(for: long) == nil)
        var flagged = long
        flagged = AppNotification(id: "4", appID: "com.example", title: "x", body: flagged.body, date: date, isOneTimePasscode: true)
        #expect(VerificationCodeDetector.item(for: flagged)?.verificationCode == "482913")
    }

    @Test func modelCodesMustAppearInTheMessage() async throws {
        let mail = note("m", app: "com.apple.mail", title: "Ant Bank", body: "你的一次性验证码是 2325，10 分钟内有效。客服 8888 6666", at: date)
        let statement = note("s", app: "com.apple.mail", title: "Ant Bank", body: "你的月结单已准备好", at: date)
        let output = #"{"actions":[{"sources":[1],"summary":"验证码 2325（Ant Bank）","due":"","priority":"high","kind":"code"},{"sources":[2],"summary":"验证码 7319（Ant Bank）","due":"","priority":"high","kind":"code"}]}"#
        let items = try await ActionExtractor(provider: StubProvider([.success(output)])).extract(from: [mail, statement])
        let real = try #require(items.first { $0.sourceIDs == ["m"] })
        #expect(real.kind == .code && real.verificationCode == "2325")
        // The model made up a number the message doesn't contain: not shown as a code.
        let invented = try #require(items.first { $0.sourceIDs == ["s"] })
        #expect(invented.kind == .notice)
    }
}

@Suite struct SourceMessagesTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func itemsKeepTheirMessagesInOrder() async throws {
        let early = note("1", app: "com.tencent.xinwechat", title: "资料群", body: "赵六: 这张表口径不一样", at: date)
        let late = note("2", app: "com.tencent.xinwechat", title: "资料群", body: "小王: 那我重新算吧", at: date.addingTimeInterval(60))
        let output = #"{"actions":[{"sources":[2,1],"summary":"小王将重新计算","due":"","priority":"low","kind":"notice"}]}"#
        let item = try #require(try await ActionExtractor(provider: StubProvider([.success(output)])).extract(from: [early, late]).first)
        #expect(item.messages == ["赵六: 这张表口径不一样", "小王: 那我重新算吧"])
    }

    @Test func mergingAppendsMessagesAndOldItemsSplitTheirExcerpt() {
        var older = ActionItem(summary: "a", appID: "x", sourceTitle: "群", sourceExcerpt: "甲: 一 / 乙: 二", notificationDate: date)
        #expect(older.messages == ["甲: 一", "乙: 二"])
        var newer = ActionItem(summary: "b", appID: "x", sourceTitle: "群", sourceExcerpt: "丙: 三", notificationDate: date)
        newer.sourceMessages = ["丙: 三"]
        older.absorb(newer)
        #expect(older.messages == ["甲: 一", "乙: 二", "丙: 三"])
    }
}

@Suite struct MergedFilesTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mergingKeepsFilesAndDropsTheirNameLines() {
        var notice = ActionItem(summary: "小王将重新计算", kind: .notice, appID: "x", sourceTitle: "资料群",
                                sourceExcerpt: "", notificationDate: date)
        notice.sourceMessages = ["赵六: 这张表口径不一样", "赵六: [文件] 估值分位.xlsx", "赵六: [图片]"]
        let file = ActionItem(summary: "收到文件 估值分位.xlsx", kind: .notice, appID: "x", sourceTitle: "资料群",
                              sourceExcerpt: "估值分位.xlsx", notificationDate: date, attachmentPath: "/tmp/估值分位.xlsx")
        notice.absorb(file)
        #expect(notice.files == ["/tmp/估值分位.xlsx"])
        #expect(notice.textMessages == ["赵六: 这张表口径不一样", "赵六: [图片]"])
        // A file item on its own shows just its box.
        #expect(file.textMessages.isEmpty)
    }
}

@Suite struct MentionedFilesTests {
    @Test func findsSentFileNames() {
        var item = ActionItem(summary: "s", appID: "com.tencent.xinwechat", sourceTitle: "群", sourceExcerpt: "",
                              notificationDate: Date())
        item.sourceMessages = ["赵六: [文件] 估值分位.xlsx", "赵六: [图片]", "王五: 收到"]
        #expect(item.mentionedFiles == ["估值分位.xlsx"])
        #expect(item.textMessages(files: ["/x/估值分位.xlsx"]) == ["赵六: [图片]", "王五: 收到"])
    }

    @Test func locatesReceivedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let folder = root.appendingPathComponent("wxid_a/msg/file/\(formatter.string(from: Date()))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("估值分位.xlsx"))
        let source = WeChatFileSource(root: root)
        #expect(source.locate(fileNamed: "估值分位.xlsx")?.lastPathComponent == "估值分位.xlsx")
        #expect(source.locate(fileNamed: "不存在.docx") == nil)
    }
}

@Suite struct SourceEntriesTests {
    private func item(_ messages: [String]) -> ActionItem {
        var item = ActionItem(summary: "s", appID: "com.tencent.xinwechat", sourceTitle: "群", sourceExcerpt: "",
                              notificationDate: Date())
        item.sourceMessages = messages
        return item
    }

    @Test func filesSitWhereTheyWereSent() {
        let entries = item(["赵六: 先看这个", "估值分位.xlsx", "赵六: [文件] 估值分位.xlsx", "赵六: [图片]", "小王: 那我重新算吧"])
            .sourceEntries(files: ["/f/估值分位.xlsx"])
        #expect(entries == [
            .text("赵六: 先看这个"),
            .file(sender: "赵六", path: "/f/估值分位.xlsx"),
            .text("赵六: [图片]"),
            .text("小王: 那我重新算吧"),
        ])
    }

    @Test func bareFileLinesAndUnmentionedFiles() {
        let entries = item(["报价单.pdf", "王五: 收到"]).sourceEntries(files: ["/f/报价单.pdf", "/f/附件.docx"])
        #expect(entries == [.file(sender: nil, path: "/f/报价单.pdf"), .text("王五: 收到"), .file(sender: nil, path: "/f/附件.docx")])
        // A "[文件]" message whose file isn't on disk stays as text.
        #expect(item(["赵六: [文件] 不在了.xlsx"]).sourceEntries(files: []) == [.text("赵六: [文件] 不在了.xlsx")])
    }
}
