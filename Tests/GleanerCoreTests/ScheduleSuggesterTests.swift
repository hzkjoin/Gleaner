import Foundation
import Testing
@testable import GleanerCore

@Suite struct ScheduleSuggesterTests {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    /// Thursday 2026-11-05 10:30 in Shanghai.
    private var now: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10, minute: 30))!
    }

    private func item(_ summary: String, due: String = "", excerpt: String = "", kind: ActionKind = .task) -> ActionItem {
        ActionItem(summary: summary, due: due, kind: kind, appID: "com.tencent.xinwechat", sourceTitle: "王总",
                   sourceExcerpt: excerpt, notificationDate: now)
    }

    private func suggester(_ output: String) -> ScheduleSuggester {
        ScheduleSuggester(provider: StubProvider([.success(output)]), appName: { _ in "微信" }, timeZone: zone)
    }

    @Test func candidatesNeedATimeAndSkipCodesAndFiles() {
        let items = [
            item("回复王总报价", due: "今天 18:00"),
            item("明天下午 3 点开评审会", excerpt: "明天下午3点评审"),
            item("看一下方案"),
            ActionItem(summary: "验证码 123456", kind: .code, appID: "a", sourceTitle: "", sourceExcerpt: "", notificationDate: now),
        ]
        #expect(ScheduleSuggester.candidates(items).map(\.summary) == ["回复王总报价", "明天下午 3 点开评审会"])
    }

    @Test func parsesEventsAndReminders() async throws {
        let items = [item("明天下午 3 点开评审会"), item("提交报送数据", due: "11 月 20 日前"), item("看一下方案")]
        let output = """
        {"suggestions":[
          {"index":1,"worth":true,"type":"event","title":"项目评审会","start":"2026-11-06T15:00","end":"2026-11-06T16:30","all_day":false,"location":"3 楼会议室","notes":""},
          {"index":2,"worth":true,"type":"reminder","title":"提交第四季度报送数据","start":"2026-11-20","end":"","all_day":true,"location":"","notes":"通过系统提交"},
          {"index":3,"worth":false,"type":"reminder","title":"","start":"","end":"","all_day":false,"location":"","notes":""}]}
        """
        let result = try await suggester(output).suggest(for: items, now: now)
        #expect(result.count == 2)
        let event = try #require(result[items[0].id]?.first)
        #expect(event.kind == .event && event.title == "项目评审会" && event.location == "3 楼会议室" && !event.allDay)
        #expect(event.effectiveEnd.timeIntervalSince(event.start) == 5400)
        let reminder = try #require(result[items[1].id]?.first)
        #expect(reminder.kind == .reminder && reminder.allDay && reminder.end == nil && reminder.notes == "通过系统提交")
    }

    @Test func dropsPastAndFarOffTimes() async throws {
        let items = [item("昨天的会"), item("今天早上的电话"), item("十年后"), item("今天全天的事")]
        let output = """
        {"suggestions":[
          {"index":1,"worth":true,"type":"event","title":"a","start":"2026-11-04T15:00","end":"","all_day":false,"location":"","notes":""},
          {"index":2,"worth":true,"type":"event","title":"b","start":"2026-11-05T08:00","end":"","all_day":false,"location":"","notes":""},
          {"index":3,"worth":true,"type":"reminder","title":"c","start":"2036-11-05","end":"","all_day":true,"location":"","notes":""},
          {"index":4,"worth":true,"type":"reminder","title":"d","start":"2026-11-05","end":"","all_day":true,"location":"","notes":""}]}
        """
        let result = try await suggester(output).suggest(for: items, now: now)
        #expect(result.keys.sorted { $0.uuidString < $1.uuidString } == [items[3].id])
    }

    @Test func promptGivesTheCurrentTimeAndSources() {
        let request = suggester("").request(for: [item("开会", due: "明天 15:00", excerpt: "明天三点开会")], now: now)
        #expect(request.system.contains("2026年11月5日 星期四 10:30"))
        #expect(request.user.contains("截止：明天 15:00"))
        #expect(request.user.contains("来源：微信 王总"))
    }

    @Test func itemsFromBeforeSuggestionsStillLoad() throws {
        var saved = item("开会")
        saved.schedules = [ScheduleSuggestion(kind: .event, title: "开会", start: now)]
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(ActionItem.self, from: data).schedules.first?.title == "开会")
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "schedules")
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(ActionItem.self, from: old).schedules.isEmpty)
    }

    @Test func oneItemCanHaveSeveralTimes() async throws {
        let items = [item("培训提醒", due: "11日、12日中午", excerpt: "11 月 11 日中午 12:30 第三课；11 月 12 日中午 12:30 第四课")]
        let output = """
        {"suggestions":[
         {"index":1,"worth":true,"type":"event","title":"培训第四课","start":"2026-11-12T12:30","end":"2026-11-12T13:30","all_day":false,"location":"","notes":""},
         {"index":1,"worth":true,"type":"event","title":"培训第三课","start":"2026-11-11T12:30","end":"2026-11-11T13:30","all_day":false,"location":"","notes":""},
         {"index":1,"worth":true,"type":"event","title":"重复","start":"2026-11-11T12:30","end":"","all_day":false,"location":"","notes":""}]}
        """
        let result = try await suggester(output).suggest(for: items, now: now)
        // In time order, the repeated time dropped.
        #expect(result[items[0].id]?.map(\.title) == ["培训第三课", "培训第四课"])
    }

    @Test func oneSavedSuggestionStillLoads() throws {
        let saved = ActionItem(summary: "开会", priority: .medium, kind: .task, appID: "a", sourceTitle: "", sourceExcerpt: "", notificationDate: now)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        json.removeValue(forKey: "schedules")
        json["schedule"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ScheduleSuggestion(kind: .event, title: "开会", start: now)))
        let loaded = try JSONDecoder().decode(ActionItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.schedules.map(\.title) == ["开会"])
    }
}
