import Foundation
import Testing
@testable import GleanerCore

struct SourceDatesTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ notes: [AppNotification]) -> ActionItem {
        var item = ActionItem(summary: "s", priority: .low, kind: .notice, appID: "com.tencent.xinwechat", sourceTitle: "群",
                              sourceExcerpt: "", notificationDate: base, sourceIDs: notes.map(\.id))
        item.setSources(notes)
        return item
    }

    func note(_ id: String, _ body: String, minutes: Double) -> AppNotification {
        AppNotification(id: id, appID: "com.tencent.xinwechat", title: "群", body: body, date: base.addingTimeInterval(minutes * 60))
    }

    @Test func eachMessageKeepsItsTime() {
        let entries = item([note("2", "张三: 后来的", minutes: 30), note("1", "张三: [图片]", minutes: 0)]).datedSourceEntries(files: [])
        #expect(entries.map(\.entry) == [.text("张三: [图片]"), .text("张三: 后来的")])
        #expect(entries.map(\.date) == [base, base.addingTimeInterval(1800)])
    }

    @Test func mergingKeepsTimes() {
        var older = item([note("1", "张三: 第一条", minutes: 0)])
        older.absorb(item([note("2", "李四: 第二条", minutes: 45)]))
        #expect(older.messages == ["张三: 第一条", "李四: 第二条"])
        #expect(older.messageDates == [base, base.addingTimeInterval(2700)])
    }

    @Test func olderItemsGetTimesFromTheirIDs() {
        var saved = ActionItem(summary: "s", priority: .low, kind: .notice, appID: "a", sourceTitle: "群", sourceExcerpt: "",
                               notificationDate: base, sourceIDs: ["1", "2"])
        saved.sourceMessages = ["张三: [图片]", "张三: 后来的"]
        saved.restoreSourceDates(["1": base, "2": base.addingTimeInterval(600)])
        #expect(saved.messageDates == [base, base.addingTimeInterval(600)])
    }

    @Test func savedItemsWithoutTimesStillDecode() throws {
        var item = item([note("1", "张三: 一", minutes: 0)])
        item.sourceDates = []
        let decoded = try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.messageDates == [nil])
    }
}
