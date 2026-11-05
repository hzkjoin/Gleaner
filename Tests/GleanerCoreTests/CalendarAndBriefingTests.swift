import Foundation
import Testing
@testable import GleanerCore

@Suite("Meeting links")
struct MeetingLinkTests {
    @Test("recognizes common meeting services", arguments: [
        ("https://meeting.tencent.com/dm/abc123", "腾讯会议"),
        ("会议链接：https://vc.feishu.cn/j/123456789 ", "飞书会议"),
        ("https://us02web.zoom.us/j/8812345678?pwd=x", "Zoom"),
        ("Join: https://teams.microsoft.com/l/meetup-join/19%3a", "Teams"),
        ("https://meet.google.com/abc-defg-hij", "Google Meet"),
        ("https://meeting.dingtalk.com/j/abcd", "钉钉会议"),
    ])
    func recognizes(text: String, service: String) {
        #expect(MeetingLinkDetector.link(in: [text])?.service == service)
    }

    @Test("ignores other links and empty fields")
    func ignores() {
        #expect(MeetingLinkDetector.link(in: [nil, "", "https://example.com/zoom.us", "3 楼会议室"]) == nil)
    }

    @Test("checks fields in order")
    func order() {
        let link = MeetingLinkDetector.link(in: ["https://meet.google.com/a", "https://meeting.tencent.com/b"])
        #expect(link?.service == "Google Meet")
    }
}

@Suite("Calendar events")
struct CalendarEventTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: String, startsIn minutes: Double, lasts: Double = 30) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(lasts * 60))
    }

    @Test("is imminent from ten minutes before until five minutes after the start")
    func imminence() {
        #expect(!event("a", startsIn: 11).isImminent(now: now))
        #expect(event("b", startsIn: 9).isImminent(now: now))
        #expect(event("c", startsIn: -4).isImminent(now: now))
        #expect(!event("d", startsIn: -6).isImminent(now: now))
    }

    func reminder(_ id: String, dueIn minutes: Double, hasTime: Bool = true) -> CalendarEvent {
        let due = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(id: id, kind: .reminder, title: id, start: due, end: due, hasTime: hasTime)
    }

    @Test("lists ongoing and later-today events, earliest first, up to a limit")
    func upcoming() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let events = [event("later", startsIn: 120), event("past", startsIn: -60), event("ongoing", startsIn: -10),
                      event("soon", startsIn: 30)]
        #expect(events.upcoming(now: now, calendar: calendar, limit: 2).map(\.id) == ["ongoing", "soon"])
    }

    @Test("reminders are imminent for half an hour after they are due and stay listed while open")
    func reminders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(reminder("a", dueIn: 4).isImminent(now: now))
        #expect(reminder("b", dueIn: -20).isImminent(now: now))
        #expect(!reminder("c", dueIn: -40).isImminent(now: now))
        #expect(!reminder("d", dueIn: 4, hasTime: false).isImminent(now: now))
        #expect(reminder("e", dueIn: -40).isOverdue(now: now) && !reminder("f", dueIn: 5).isOverdue(now: now))

        let items = [reminder("overdue", dueIn: -90), event("past", startsIn: -60), reminder("soon", dueIn: 4)]
        #expect(items.upcoming(now: now, calendar: calendar).map(\.id) == ["overdue", "soon"])
    }
}

@Suite("Grouping and briefing")
struct GroupingAndBriefingTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ summary: String, from title: String, app: String = "com.tencent.xinwechat") -> ActionItem {
        ActionItem(summary: summary, appID: app, sourceTitle: title, sourceExcerpt: "", notificationDate: date)
    }

    @Test("groups items by conversation in order of first appearance")
    func groups() {
        let grouped = [item("a", from: "小李"), item("b", from: "王总"), item("c", from: "小李"),
                       item("d", from: "小李", app: "com.tencent.weworkmac")].groupedByConversation()
        #expect(grouped.map { $0.map(\.summary) } == [["a", "c"], ["b"], ["d"]])
    }

    @Test("sends each briefing once, within an hour of its time")
    func dueSlots() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: hour, minute: minute))!
        }
        #expect(Briefing.dueSlot(now: at(8, 59), lastSent: nil, calendar: calendar) == nil)
        #expect(Briefing.dueSlot(now: at(9, 5), lastSent: nil, calendar: calendar) == at(9))
        #expect(Briefing.dueSlot(now: at(9, 5), lastSent: at(9, 1), calendar: calendar) == nil)
        #expect(Briefing.dueSlot(now: at(15), lastSent: nil, calendar: calendar) == nil)
        #expect(Briefing.dueSlot(now: at(18, 30), lastSent: at(9, 1), calendar: calendar) == at(18))
    }

    @Test("says nothing when there is nothing to report")
    func message() {
        #expect(Briefing.message(actionable: 3, news: 2) == "3 件待处理，2 条热点")
        #expect(Briefing.message(actionable: 0, news: 1) == "1 条热点")
        #expect(Briefing.message(actionable: 0, news: 0) == nil)
    }
}

@Suite("Conversation merging")
struct ConversationMergingTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ summary: String, from title: String, kind: ActionKind = .reply, priority: Priority = .medium,
              due: String = "", minutes: Double = 0, id: String = UUID().uuidString) -> ActionItem {
        let at = date.addingTimeInterval(minutes * 60)
        return ActionItem(summary: summary, due: due, priority: priority, kind: kind, appID: "com.tencent.xinwechat",
                          sourceTitle: title, sourceExcerpt: summary, notificationDate: at, createdAt: at, sourceIDs: [id])
    }

    @Test("similar summaries", arguments: [
        ("回复王总报价单", "尽快回复王总报价单", true),
        ("发送报价单给王总", "发送报价单", true),
        ("回复私聊提问", "回复私聊问题", true),
        ("发报价单", "确认明天开会时间", false),
        ("回复王总问题", "回复王总报价", false),
        ("", "回复", false),
    ])
    func similarity(a: String, b: String, expected: Bool) {
        #expect(SummarySimilarity.isSimilar(a, b, ignoring: "王总") == expected)
    }

    @Test("folds a repeat into the open item and keeps distinct requests apart")
    func merging() {
        var existing = item("回复王总报价单", from: "王总", priority: .medium, id: "n1")
        existing.snoozedUntil = date.addingTimeInterval(3600)
        let merged = [existing].merging([
            item("尽快回复王总报价单", from: "王总", priority: .high, due: "今天 18:00", minutes: 20, id: "n2"),
            item("确认明天开会时间", from: "王总", minutes: 21, id: "n3"),
            item("回复王总报价单", from: "李总", minutes: 22, id: "n4"),
            item("回复王总报价单", from: "王总", kind: .task, minutes: 23, id: "n5"),
        ])
        #expect(merged.count == 4)
        let folded = merged[0]
        #expect(folded.summary == "尽快回复王总报价单")
        #expect(folded.due == "今天 18:00" && folded.priority == .high)
        #expect(folded.notificationDate == date.addingTimeInterval(20 * 60))
        #expect(folded.snoozedUntil == nil)
        #expect(folded.sourceIDs == ["n1", "n2"])
        #expect(folded.sourceExcerpt == "回复王总报价单 / 尽快回复王总报价单")
    }

    @Test("keeps different codes apart and the same code once")
    func codesStayApart() {
        let code = item("验证码 111111", from: "106900", kind: .code)
        #expect([code].merging([item("验证码 222222", from: "106900", kind: .code)]).count == 2)
        #expect([code].merging([item("验证码 111111", from: "106900", kind: .code)]).count == 1)
    }

    @Test("one card per conversation, under its most pressing kind; codes on their own")
    func sections() {
        let items = [
            item("确认报价", from: "王总", kind: .task),
            item("回复提问", from: "王总", kind: .reply),
            item("订单已送达", from: "美团", kind: .notice),
            item("验证码 1", from: "106900", kind: .code),
            item("验证码 2", from: "106900", kind: .code),
        ]
        let sections = items.conversationSections(order: [.code, .reply, .task, .alert, .notice])
        #expect(sections.map(\.kind) == [.code, .reply, .notice])
        #expect(sections[0].groups.map(\.count) == [1, 1])
        #expect(sections[1].groups.first?.map(\.summary) == ["确认报价", "回复提问"])
    }
}
