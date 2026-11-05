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
    ])
    func finds(text: String, expected: String) {
        #expect(VerificationCodeDetector.code(in: text) == expected)
    }

    @Test("ignores messages that are not verification codes", arguments: [
        "订单 20261104 已发货",
        "会议改到 1530 开始",
        "请输入验证码",
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
