import Foundation
import Testing
@testable import GleanerCore

@Suite("MentionAnalyzer")
struct MentionAnalyzerTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let analyzer = MentionAnalyzer(userNames: ["小明", "Ming"])

    func addressee(_ body: String, app: String = "com.example.chat") -> MentionAnalyzer.Addressee {
        analyzer.addressee(of: note("x", app: app, body: body, at: date))
    }

    @Test("extracts mention tokens but not email addresses")
    func tokens() {
        #expect(MentionAnalyzer.mentions(in: "黄总: @Alex @李四\u{2005}你们安排资源") == ["Alex", "李四"])
        #expect(MentionAnalyzer.mentions(in: "发到 ming@example.com 就行").isEmpty)
        #expect(MentionAnalyzer.mentions(in: "@ALexxx🍉🍉 你来协调") == ["ALexxx🍉🍉"])
    }

    @Test("recognizes the user, everyone, others and no mention", arguments: [
        ("黄总: @小明 你来讲下方案", MentionAnalyzer.Addressee.user),
        ("黄总: @Ming_Wang 看下", .user),
        ("群主: @所有人 周五前交周报", .everyone),
        ("@all please review", .everyone),
        ("黄总: @李四 @王五 你们安排一下资源", .others),
        ("张三: 今天的会改到下午了", .unspecified),
    ])
    func classifies(body: String, expected: MentionAnalyzer.Addressee) {
        #expect(addressee(body) == expected)
    }

    @Test("matches one-letter names exactly, longer names by containment")
    func nameMatching() {
        let short = MentionAnalyzer(userNames: ["霍振坤", "K"])
        func check(_ body: String) -> MentionAnalyzer.Addressee { short.addressee(of: note("x", body: body, at: date)) }
        #expect(check("黄总: @Alex @Bob 你们安排资源") == .others)
        #expect(check("黄总: @K 你看下") == .user)
        #expect(check("黄总: @k 你看下") == .user)
        #expect(check("黄总: @K（霍振坤） 你看下") == .user)
        #expect(check("黄总: @Kevin 你看下") == .others)
    }

    @Test("marks group chat messages that mention nobody", arguments: [
        ("com.tencent.xinwechat", "张三: 估值这块大家怎么看？", MentionAnalyzer.Addressee.nobodyInGroup),
        ("com.tencent.weworkmac", "李四：明天的会改到下午", .nobodyInGroup),
        ("com.tencent.xinwechat", "估值这块你怎么看？", .unspecified),
        ("com.apple.mail", "Hi: please review the attached file", .unspecified),
    ])
    func groupMessages(app: String, body: String, expected: MentionAnalyzer.Addressee) {
        #expect(addressee(body, app: app) == expected)
    }

    @Test("cannot rule the user out when their names are unknown")
    func unknownNames() {
        let anonymous = MentionAnalyzer(userNames: [" "])
        #expect(anonymous.addressee(of: note("x", body: "@李四 看下", at: date)) == .unspecified)
    }
}

@Suite("ActionExtractor filtering and retries")
struct ActionExtractorFilteringTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("does not send messages that only @mention other people")
    func skipsOthers() async throws {
        let provider = StubProvider(always: #"{"actions":[]}"#)
        let extractor = ActionExtractor(provider: provider, userNames: ["小明"])
        let items = try await extractor.extract(from: [note("1", body: "黄总: @李四 你们安排一下", at: date)])
        #expect(items.isEmpty)
        #expect(provider.receivedRequests.isEmpty)
    }

    @Test("tags messages that @mention the user or everyone, and renumbers after filtering")
    func tagsAndRenumbers() async throws {
        let provider = StubProvider(always: actionsJSON([([2], "准备方案")]))
        let extractor = ActionExtractor(provider: provider, userNames: ["小明"])
        let items = try await extractor.extract(from: [
            note("1", body: "黄总: @李四 你们安排一下", at: date),
            note("2", body: "群主: @所有人 周五前交周报", at: date),
            note("3", title: "项目群", body: "黄总: @小明 明早你讲下方案", at: date),
        ])
        let prompt = try #require(provider.receivedRequests.first?.user)
        #expect(!prompt.contains("@李四"))
        #expect(prompt.contains("[1]") && prompt.contains("【@所有人】群主"))
        #expect(prompt.contains("[2]") && prompt.contains("【@我】黄总"))
        #expect(items.first?.sourceExcerpt == "黄总: @小明 明早你讲下方案")
    }

    @Test("demotes items from group messages that mention nobody to low-priority notices")
    func demotesUnaddressedGroupMessages() async throws {
        let provider = StubProvider(always: #"{"actions":[{"sources":[1],"summary":"回答统计问题","priority":"high","kind":"reply"},{"sources":[2],"summary":"回复王总","priority":"high","kind":"reply"}]}"#)
        let extractor = ActionExtractor(provider: provider, userNames: ["小明"])
        let items = try await extractor.extract(from: [
            note("1", app: "com.tencent.xinwechat", title: "资料群", body: "张三: 估值这块大家怎么看？", at: date),
            note("2", app: "com.tencent.xinwechat", title: "王总", body: "估值这块你怎么看？", at: date),
        ])
        #expect(items.map(\.kind) == [.notice, .reply])
        #expect(items.map(\.priority) == [.low, .high])
        let prompt = try #require(provider.receivedRequests.first?.user)
        #expect(prompt.contains("【群消息未@人】张三"))
    }

    @Test("asks again when the model returns an unusable answer")
    func retriesOnce() async throws {
        let provider = StubProvider([.success("{\n\n}"), .success(actionsJSON([([1], "回复张三")]))])
        let items = try await ActionExtractor(provider: provider).extract(from: [note("1", body: "在吗", at: date)])
        #expect(items.map(\.summary) == ["回复张三"])
        #expect(provider.receivedRequests.count == 2)
    }

    @Test("treats two empty answers in a row as nothing to report")
    func emptyTwice() async throws {
        let provider = StubProvider([.success("{\n\n}"), .success("```json\n{}\n```")])
        let items = try await ActionExtractor(provider: provider).extract(from: [note("1", body: "在吗", at: date)])
        #expect(items.isEmpty)
    }

    @Test("still fails on two malformed answers")
    func malformedTwice() async {
        let provider = StubProvider([.success("not json"), .success("still not json")])
        await #expect(throws: LLMError.self) {
            try await ActionExtractor(provider: provider).extract(from: [note("1", body: "在吗", at: date)])
        }
    }
}
