import Foundation
import Testing
@testable import GleanerCore

@Suite("Item lifecycle")
struct ItemLifecycleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(kind: ActionKind = .task, foundMinutesAgo: Double, snoozedUntil: Date? = nil) -> ActionItem {
        let date = now.addingTimeInterval(-foundMinutesAgo * 60)
        return ActionItem(summary: "x", kind: kind, appID: "a", sourceTitle: "", sourceExcerpt: "",
                          notificationDate: date, createdAt: date, snoozedUntil: snoozedUntil)
    }

    @Test("codes expire after ten minutes, other items after a day")
    func expiry() {
        #expect(!ItemLifecycle.isExpired(item(kind: .code, foundMinutesAgo: 9), now: now))
        #expect(ItemLifecycle.isExpired(item(kind: .code, foundMinutesAgo: 11), now: now))
        #expect(!ItemLifecycle.isExpired(item(foundMinutesAgo: 60 * 23), now: now))
        #expect(ItemLifecycle.isExpired(item(foundMinutesAgo: 60 * 25), now: now))
    }

    @Test("a snoozed item is hidden until its time and ages from then")
    func snooze() {
        let hidden = item(foundMinutesAgo: 60 * 30, snoozedUntil: now.addingTimeInterval(60))
        #expect(!ItemLifecycle.isVisible(hidden, now: now))
        #expect(!ItemLifecycle.isExpired(hidden, now: now))

        let back = item(foundMinutesAgo: 60 * 30, snoozedUntil: now.addingTimeInterval(-60))
        #expect(ItemLifecycle.isVisible(back, now: now))
        #expect(!ItemLifecycle.isExpired(back, now: now))
    }

    @Test("only codes that just arrived are fresh")
    func freshCodes() {
        #expect(ItemLifecycle.isFreshCode(item(kind: .code, foundMinutesAgo: 1), now: now))
        #expect(!ItemLifecycle.isFreshCode(item(kind: .code, foundMinutesAgo: 5), now: now))
        #expect(!ItemLifecycle.isFreshCode(item(kind: .task, foundMinutesAgo: 1), now: now))
    }

    @Test("snooze options land at sensible times")
    func snoozeOptions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: hour, minute: minute))!
        }
        #expect(SnoozeOption.oneHour.date(from: at(10), calendar: calendar) == at(11))
        #expect(SnoozeOption.tonight.date(from: at(10), calendar: calendar) == at(20))
        #expect(SnoozeOption.tonight.date(from: at(19, 30), calendar: calendar) == nil)
        let tomorrow = try #require(SnoozeOption.tomorrowMorning.date(from: at(23), calendar: calendar))
        #expect(calendar.component(.day, from: tomorrow) == 5 && calendar.component(.hour, from: tomorrow) == 9)
    }

    @Test("items saved before snoozing existed still decode")
    func legacyDecoding() throws {
        let json = """
        {"id":"\(UUID().uuidString)","summary":"x","appID":"a","notificationDate":"2026-11-04T09:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ActionItem.self, from: Data(json.utf8)).snoozedUntil == nil)
    }
}

@Suite("NotificationFilter")
struct NotificationFilterTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("blocks ignored apps and muted conversations only")
    func filters() {
        let filter = NotificationFilter(
            ignoredApps: ["com.apple.Music"],
            mutedConversations: [ConversationKey(appID: "com.tencent.xinwechat", title: "资料群")]
        )
        #expect(!filter.allows(note("1", app: "com.apple.Music", title: "x", body: "y", at: date)))
        #expect(!filter.allows(note("2", app: "com.tencent.xinwechat", title: "资料群", body: "y", at: date)))
        #expect(filter.allows(note("3", app: "com.tencent.xinwechat", title: "项目群", body: "y", at: date)))
        #expect(filter.allows(note("4", app: "com.tencent.weworkmac", title: "资料群", body: "y", at: date)))

        let mutedItem = ActionItem(summary: "x", appID: "com.tencent.xinwechat", sourceTitle: "资料群",
                                   sourceExcerpt: "", notificationDate: date)
        #expect(!filter.allows(mutedItem))
    }

    @Test("the pipeline never sends muted conversations to the model")
    func pipelineUsesFilter() async throws {
        let source = FakeSource()
        source.add([
            note("1", app: "com.tencent.xinwechat", title: "资料群", body: "张三: 大家填一下", at: date.addingTimeInterval(1)),
            note("2", app: "com.tencent.xinwechat", title: "王总", body: "报价单发我", at: date.addingTimeInterval(2)),
        ])
        let provider = StubProvider(always: #"{"actions":[]}"#)
        let pipeline = NotificationPipeline(source: source, stateStore: nil, now: date)
        let filter = NotificationFilter(mutedConversations: [ConversationKey(appID: "com.tencent.xinwechat", title: "资料群")])
        try await pipeline.run(extractor: ActionExtractor(provider: provider), filter: filter) { _ in }

        let prompt = try #require(provider.receivedRequests.first?.user)
        #expect(prompt.contains("报价单") && !prompt.contains("填一下"))
    }

    @Test("counter-examples are added to the prompt")
    func counterExamples() async throws {
        let provider = StubProvider(always: #"{"actions":[]}"#)
        let extractor = ActionExtractor(provider: provider, irrelevantExamples: ["回答统计问题（资料群）"])
        _ = try await extractor.extract(from: [note("1", body: "在吗", at: date)])
        let system = try #require(provider.receivedRequests.first?.system)
        #expect(system.contains("不相关") && system.contains("回答统计问题（资料群）"))
        #expect(!ExtractionPrompt.system(userNames: []).contains("不相关】"))
    }
}
