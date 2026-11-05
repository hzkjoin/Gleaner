import Foundation
import Testing
@testable import GleanerCore

@Suite("ConversationArchive")
struct ConversationArchiveTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func message(_ id: String, _ title: String, _ body: String, minutes: Double, app: String = "com.tencent.xinwechat",
                 fromMe: Bool = false) -> ArchivedMessage {
        ArchivedMessage(id: id, appID: app, title: title, body: body, date: base.addingTimeInterval(minutes * 60), fromMe: fromMe)
    }

    @Test("keeps each conversation in time order, without duplicates")
    func ordering() {
        let archive = ConversationArchive(store: nil, retention: .infinity)
        archive.add([message("2", "王总", "报价单发我", minutes: 2), message("1", "王总", "在吗", minutes: 1),
                     message("3", "李四", "开会", minutes: 3)])
        archive.add([message("2", "王总", "报价单发我", minutes: 2),                       // same id
                     message("2b", "王总", "报价单发我", minutes: 3),                      // same text from another source
                     message("4", "王总", "好", minutes: 9, app: "COM.TENCENT.XINWECHAT")])  // case-insensitive app
        let wang = archive.messages(in: ConversationKey(appID: "com.tencent.xinwechat", title: "王总"))
        #expect(wang.map(\.id) == ["1", "2", "4"])
        #expect(archive.recent(since: base).map(\.id) == ["1", "2", "3", "4"])
    }

    @Test("prunes by age and by count per conversation, and persists")
    func pruning() throws {
        let store = JSONFileStore<[ArchivedMessage]>(url: temporaryDirectory().appendingPathComponent("archive.json"))
        let now = Date()
        let archive = ConversationArchive(store: store, retention: 3600, perConversationLimit: 2)
        archive.add([
            ArchivedMessage(id: "old", appID: "a", title: "t", body: "x", date: now.addingTimeInterval(-7200)),
            ArchivedMessage(id: "1", appID: "a", title: "t", body: "一", date: now.addingTimeInterval(-30)),
            ArchivedMessage(id: "2", appID: "a", title: "t", body: "二", date: now.addingTimeInterval(-20)),
            ArchivedMessage(id: "3", appID: "a", title: "t", body: "三", date: now.addingTimeInterval(-10)),
        ])
        #expect(archive.messages(in: ConversationKey(appID: "a", title: "t")).map(\.id) == ["2", "3"])
        let reloaded = ConversationArchive(store: store, retention: 3600, perConversationLimit: 2)
        #expect(reloaded.messages(in: ConversationKey(appID: "a", title: "t")).map(\.id) == ["2", "3"])
    }

    @Test("renders a transcript marking the user's own messages")
    func transcript() {
        let text = ConversationArchive.transcript([message("1", "王总", "报价单发我", minutes: 0),
                                                   message("2", "王总", "好的，下班前发", minutes: 1, fromMe: true)])
        #expect(text.contains(" 报价单发我") && text.contains(" 我: 好的，下班前发"))
    }

    @Test("the pipeline archives messages, including the user's own, but never analyzes the user's own")
    func pipelineFeedsArchive() async throws {
        let source = FakeSource()
        source.add([
            AppNotification(id: "in", appID: "com.apple.MobileSMS", title: "妈妈", body: "晚上回家吃饭吗", date: base.addingTimeInterval(1)),
            AppNotification(id: "out", appID: "com.apple.MobileSMS", title: "妈妈", body: "回的，七点到",
                            date: base.addingTimeInterval(2), isFromUser: true),
        ])
        let archive = ConversationArchive(store: nil, retention: .infinity)
        let provider = StubProvider(always: #"{"actions":[]}"#)
        try await NotificationPipeline(source: source, stateStore: nil, now: base)
            .run(extractor: ActionExtractor(provider: provider), archive: archive) { _ in }

        #expect(archive.messages(in: ConversationKey(appID: "com.apple.MobileSMS", title: "妈妈")).map(\.fromMe) == [false, true])
        let prompt = try #require(provider.receivedRequests.first?.user)
        #expect(prompt.contains("晚上回家吃饭吗") && !prompt.contains("七点到"))
    }
}

@Suite("User rules")
struct UserRuleTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    func note(_ title: String, _ body: String, at components: DateComponents, app: String = "com.tencent.xinwechat") -> AppNotification {
        AppNotification(id: UUID().uuidString, appID: app, title: title, body: body, date: calendar.date(from: components)!)
    }

    // 2026-11-07 is a Saturday.
    let saturday23 = DateComponents(year: 2026, month: 11, day: 7, hour: 23)
    let wednesday10 = DateComponents(year: 2026, month: 11, day: 4, hour: 10)

    @Test("matches app name, conversation and keyword fragments")
    func fragments() {
        let rule = UserRule(text: "王总的消息都标紧急", action: .urgent, app: "微信", conversation: "王总")
        #expect(rule.matches(note("王总", "在吗", at: wednesday10), appName: "微信", calendar: calendar))
        #expect(!rule.matches(note("李总", "在吗", at: wednesday10), appName: "微信", calendar: calendar))
        let keyword = UserRule(text: "快递通知不用提醒", action: .ignore, keyword: "快递")
        #expect(keyword.matches(note("顺丰", "您的快递已签收", at: wednesday10), appName: "顺丰", calendar: calendar))
    }

    @Test("respects weekdays and hours that wrap midnight")
    func timing() {
        let weekend = UserRule(text: "周末不提醒工作群", action: .ignore, conversation: "工作群", weekdays: [6, 7])
        #expect(weekend.matches(note("产品工作群", "x", at: saturday23), appName: "微信", calendar: calendar))
        #expect(!weekend.matches(note("产品工作群", "x", at: wednesday10), appName: "微信", calendar: calendar))
        let night = UserRule(text: "晚上十点后不提醒", action: .ignore, hours: [22, 8])
        #expect(night.matches(note("a", "x", at: saturday23), appName: "微信", calendar: calendar))
        #expect(!night.matches(note("a", "x", at: wednesday10), appName: "微信", calendar: calendar))
    }

    @Test("reads back concisely")
    func summary() {
        #expect(UserRule(text: "", action: .urgent, app: "微信", conversation: "王总").summary == "微信，王总：紧急")
        #expect(UserRule(text: "", action: .ignore, conversation: "工作群", weekdays: [6, 7]).summary == "工作群，周末：忽略")
    }

    @Test("ignore rules keep messages from the model; urgent rules raise priority")
    func pipelineRules() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let source = FakeSource()
        source.add([
            AppNotification(id: "ship", appID: "com.sf.express", title: "顺丰", body: "您的快递已签收", date: start.addingTimeInterval(1)),
            AppNotification(id: "boss", appID: "com.tencent.xinwechat", title: "王总", body: "报价单发我", date: start.addingTimeInterval(2)),
        ])
        let provider = StubProvider(always: #"{"actions":[{"sources":[1],"summary":"发报价单","priority":"medium","kind":"task"}]}"#)
        let filter = NotificationFilter(rules: [
            UserRule(text: "快递通知不用提醒", action: .ignore, keyword: "快递"),
            UserRule(text: "王总的消息都标紧急", action: .urgent, conversation: "王总"),
        ])
        actor Log { var items: [ActionItem] = []; var records: [ActivityRecord] = []
            func add(_ e: PipelineEvent) {
                if case .extracted(let i, _) = e { items += i }
                if case .activity(let r) = e { records += r }
            } }
        let log = Log()
        try await NotificationPipeline(source: source, stateStore: nil, now: start)
            .run(extractor: ActionExtractor(provider: provider), filter: filter) { await log.add($0) }

        #expect(await log.items.map(\.priority) == [.high])
        #expect(await log.records.first { $0.id == "ship" }?.outcome == .skipped(.rule))
        #expect(provider.receivedRequests.first?.user.contains("快递") == false)
    }
}

@Suite("Context-aware replies")
struct ContextReplyTests {
    @Test("the reply prompt carries the conversation's recent messages")
    func includesHistory() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = StubProvider(always: #"{"replies":[{"id":1,"reply":"好，七点到"}]}"#)
        let history = [ArchivedMessage(id: "h", appID: "com.apple.MobileSMS", title: "妈妈", body: "回的", date: date, fromMe: true)]
        let writer = ReplyWriter(provider: provider, context: { _ in history })
        let item = ActionItem(summary: "回复妈妈", kind: .reply, appID: "com.apple.MobileSMS", sourceTitle: "妈妈",
                              sourceExcerpt: "几点到？", notificationDate: date)
        let result = await writer.addReplies(to: [item], userNames: [])
        #expect(result.first?.suggestedReply == "好，七点到")
        let prompt = try #require(provider.receivedRequests.first)
        #expect(prompt.user.contains("最近的聊天记录") && prompt.user.contains("我: 回的"))
        #expect(prompt.system.contains("我:"))
    }
}

@Suite struct ArchiveSearchTests {
    private func message(_ id: String, title: String, body: String, daysAgo: Double) -> ArchivedMessage {
        ArchivedMessage(id: id, appID: "com.tencent.xinwechat", title: title, body: body,
                        date: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    @Test func termsDropQuestionWords() {
        let terms = ConversationArchive.searchTerms("上周王总说的报价是多少？PDF")
        #expect(terms.contains("王总"))
        #expect(terms.contains("报价"))
        #expect(terms.contains("pdf"))
        #expect(!terms.contains("上周"))
        #expect(!terms.contains("多少"))
    }

    @Test func findsOlderMatchesBestFirst() {
        let archive = ConversationArchive(store: nil)
        archive.add([
            message("1", title: "王总", body: "报价单下周给你", daysAgo: 4),
            message("2", title: "项目群", body: "王总: 报价再降 5%", daysAgo: 3),
            message("3", title: "饭搭子", body: "今天吃什么", daysAgo: 3),
            message("4", title: "王总", body: "报价已收到", daysAgo: 0.1),  // recent: covered elsewhere
        ])
        let found = archive.search("上周王总说的报价是多少", before: Date().addingTimeInterval(-86_400))
        #expect(Set(found.map(\.id)) == ["1", "2"])
        #expect(found.map(\.id) == ["1", "2"])  // oldest first
        #expect(archive.search("天气怎么样", before: Date()).isEmpty)
    }

    @Test func questionsGetEarlierMessages() {
        let note = Assistant.earlierNote([message("1", title: "王总", body: "报价单下周给你", daysAgo: 4)], appName: { _ in "微信" })
        #expect(note.contains("更早的相关消息"))
        #expect(note.contains("报价单下周给你"))
        #expect(Assistant.earlierNote([], appName: { $0 }).isEmpty)
    }
}
