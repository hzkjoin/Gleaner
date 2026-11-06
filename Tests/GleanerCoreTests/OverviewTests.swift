import Foundation
import Testing
@testable import GleanerCore

struct OverviewTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ summary: String, _ kind: ActionKind, due: String = "") -> ActionItem {
        ActionItem(summary: summary, due: due, priority: kind == .notice ? .low : .medium, kind: kind,
                   appID: "com.tencent.xinwechat", sourceTitle: "群", sourceExcerpt: summary, notificationDate: now)
    }

    @Test func linesPointAtTheirItems() {
        let items = [item("给方案意见", .task, due: "下午"), item("回复陈静", .reply), item("执勤提醒", .notice)]
        let output = #"{"headline":"有 2 件事要你处理","first":[{"items":[1,9],"text":"周凯要方案意见"}],"quick":[{"items":[2,1],"text":"回陈静"}],"later":"一条执勤提醒","advice":"先回陈静"}"#
        let overview = try! #require(Assistant.parseOverview(output, items: items, now: now))
        #expect(overview.headline == "有 2 件事要你处理")
        // Out-of-range numbers are dropped, and an item is used once.
        #expect(overview.first == [Overview.Line(text: "周凯要方案意见", itemIDs: [items[0].id])])
        #expect(overview.quick == [Overview.Line(text: "回陈静", itemIDs: [items[1].id])])
        #expect(overview.itemIDs == Set(items.map(\.id)))
        #expect(overview.briefing == "有 2 件事要你处理\n先回陈静")
    }

    @Test func rejectsOutputWithoutAHeadline() {
        #expect(Assistant.parseOverview(#"{"first":[]}"#, items: [], now: now) == nil)
    }

    @Test func nothingOpenNeedsNoModel() async throws {
        let provider = StubProvider([])
        let codeOnly = [item("验证码 123456", .code)]
        let overview = try await Assistant(provider: provider).overview(of: codeOnly, now: now)
        #expect(overview.headline == "暂时没有要处理的事")
        #expect(provider.receivedRequests.isEmpty)
    }

    @Test func promptListsItemsWithTheirMessages() {
        var task = item("给方案意见", .task, due: "下午评审前")
        task.setSources([AppNotification(id: "1", appID: "com.tencent.xinwechat", title: "周凯", body: "下午评审前给我个意见", date: now)])
        let request = Assistant(provider: StubProvider([])).overviewRequest(items: [task], now: now, appName: { _ in "微信" })
        #expect(request.user.contains("[1] 待办"))
        #expect(request.user.contains("截止：下午评审前"))
        #expect(request.user.contains("下午评审前给我个意见"))
        #expect(request.system.contains(RecordNote.text))
    }

    @Test func newMessagesInAnItemMakeItStale() {
        var reply = item("回复陈静", .reply)
        let before = Overview.signature(of: [reply])
        reply.absorb(item("回复陈静明天能否过去", .reply))
        #expect(Overview.signature(of: [reply]) != before)
        // Codes don't count.
        #expect(Overview.signature(of: [reply, item("验证码 1", .code)]) == Overview.signature(of: [reply]))
    }
}
