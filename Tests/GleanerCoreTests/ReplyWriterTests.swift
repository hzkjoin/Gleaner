import Foundation
import Testing
@testable import GleanerCore

@Suite("ReplyWriter")
struct ReplyWriterTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ summary: String, kind: ActionKind, title: String = "王总", excerpt: String = "报价单今天发我") -> ActionItem {
        ActionItem(summary: summary, kind: kind, appID: "com.tencent.xinwechat", sourceTitle: title,
                   sourceExcerpt: excerpt, notificationDate: date)
    }

    @Test("drafts replies only for reply and task items, in order")
    func draftsReplies() async throws {
        let provider = StubProvider(always: #"{"replies":[{"id":1,"reply":" 好的，下班前发你 "},{"id":2,"reply":"有空啊"}]}"#)
        let items = [
            item("发报价单", kind: .task),
            item("验证码 482913", kind: .code),
            item("回复周末吃饭", kind: .reply, title: "老张", excerpt: "周末有空吃饭吗"),
            item("处理打卡异常", kind: .alert),
        ]
        let result = await ReplyWriter(provider: provider).addReplies(to: items, userNames: ["小明"])

        #expect(result.map(\.suggestedReply) == ["好的，下班前发你", "", "有空啊", ""])
        let request = try #require(provider.receivedRequests.first)
        #expect(request.system.contains("小明"))
        #expect(request.user.contains("[1] 来自：王总") && request.user.contains("[2] 来自：老张"))
        #expect(!request.user.contains("验证码"))
    }

    @Test("skips the model when nothing needs a reply")
    func nothingToDo() async {
        let provider = StubProvider(always: "")
        let items = [item("验证码 1234", kind: .code)]
        #expect(await ReplyWriter(provider: provider).addReplies(to: items, userNames: []) == items)
        #expect(provider.receivedRequests.isEmpty)
    }

    @Test("leaves items unchanged when the model fails or answers out of range")
    func toleratesFailures() async {
        let items = [item("发报价单", kind: .task)]
        let failing = StubProvider([.failure(TestError())])
        #expect(await ReplyWriter(provider: failing).addReplies(to: items, userNames: []) == items)

        let outOfRange = StubProvider(always: #"{"replies":[{"id":5,"reply":"x"}]}"#)
        #expect(await ReplyWriter(provider: outOfRange).addReplies(to: items, userNames: []) == items)
    }

    @Test("is used by the extractor after extraction")
    func usedByExtractor() async throws {
        let extractor = ActionExtractor(
            provider: StubProvider(always: #"{"actions":[{"sources":[1],"summary":"发报价单","kind":"task"}]}"#),
            replyWriter: ReplyWriter(provider: StubProvider(always: #"{"replies":[{"id":1,"reply":"好的"}]}"#))
        )
        let items = try await extractor.extract(from: [note("1", title: "王总", body: "报价单今天发我", at: date)])
        #expect(items.first?.suggestedReply == "好的")
    }
}
