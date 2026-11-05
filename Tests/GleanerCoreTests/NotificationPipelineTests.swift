import Foundation
import Testing
@testable import GleanerCore

@Suite("NotificationPipeline")
struct NotificationPipelineTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Collects pipeline events from the `@Sendable` callback.
    actor Recorder {
        var items: [ActionItem] = []
        var analyzed = 0
        var batches = 0

        func record(_ event: PipelineEvent) {
            switch event {
            case .analyzing: batches += 1
            case .extracted(let new, let count):
                items += new
                analyzed += count
            case .news, .activity: break
            }
        }
    }

    func makePipeline(_ source: NotificationSource, store: JSONFileStore<PipelineState>? = nil,
                      batchSize: Int = 40) -> NotificationPipeline {
        NotificationPipeline(source: source, stateStore: store, batchSize: batchSize,
                             initialLookback: 3600, now: start)
    }

    @Test("extracts items from new notifications and skips them on the next run")
    func processesOnce() async throws {
        let source = FakeSource()
        source.add([note("1", body: "明天交方案吗？", at: start.addingTimeInterval(10))])
        let provider = StubProvider(always: actionsJSON([([1], "回复方案时间")]))
        let pipeline = makePipeline(source)
        let recorder = Recorder()

        try await pipeline.run(extractor: ActionExtractor(provider: provider)) { await recorder.record($0) }
        try await pipeline.run(extractor: ActionExtractor(provider: provider)) { await recorder.record($0) }

        #expect(await recorder.items.map(\.summary) == ["回复方案时间"])
        #expect(provider.receivedRequests.count == 1)
    }

    @Test("ignores old, empty and ignored-app notifications")
    func filters() async throws {
        let source = FakeSource()
        source.add([
            note("old", body: "一小时前之前的消息", at: start.addingTimeInterval(-7200)),
            note("empty", title: "", body: "  ", at: start.addingTimeInterval(1)),
            note("music", app: "com.apple.Music", body: "正在播放", at: start.addingTimeInterval(2)),
            note("keep", body: "请审批", at: start.addingTimeInterval(3)),
        ])
        let provider = StubProvider(always: #"{"actions":[]}"#)
        let recorder = Recorder()

        try await makePipeline(source).run(extractor: ActionExtractor(provider: provider),
                                           filter: NotificationFilter(ignoredApps: ["com.apple.Music"])) { await recorder.record($0) }

        let prompt = try #require(provider.receivedRequests.first?.user)
        #expect(prompt.contains("请审批"))
        #expect(!prompt.contains("正在播放"))
        #expect(!prompt.contains("一小时前"))
        #expect(await recorder.analyzed == 1)
    }

    @Test("splits work into batches")
    func batches() async throws {
        let source = FakeSource()
        source.add((1...5).map { note("\($0)", body: "消息\($0)", at: start.addingTimeInterval(Double($0))) })
        let provider = StubProvider(always: #"{"actions":[]}"#)
        let recorder = Recorder()

        try await makePipeline(source, batchSize: 2).run(extractor: ActionExtractor(provider: provider)) {
            await recorder.record($0)
        }
        #expect(await recorder.batches == 3)
        #expect(await recorder.analyzed == 5)
    }

    @Test("keeps finished batches when a later batch fails, and retries only the rest")
    func resumesAfterFailure() async throws {
        let source = FakeSource()
        source.add((1...4).map { note("\($0)", body: "消息\($0)", at: start.addingTimeInterval(Double($0))) })
        let provider = StubProvider([.success(#"{"actions":[]}"#), .failure(TestError()), .success(#"{"actions":[]}"#)])
        let pipeline = makePipeline(source, batchSize: 2)
        let recorder = Recorder()

        await #expect(throws: TestError.self) {
            try await pipeline.run(extractor: ActionExtractor(provider: provider)) { await recorder.record($0) }
        }
        try await pipeline.run(extractor: ActionExtractor(provider: provider)) { await recorder.record($0) }

        let prompts = provider.receivedRequests.map(\.user)
        #expect(prompts.count == 3)
        #expect(prompts[2].contains("消息3") && prompts[2].contains("消息4"))
        #expect(!prompts[2].contains("消息1"))
        #expect(await recorder.analyzed == 4)
    }

    @Test("surfaces verification codes before the model answers, once, even when the model fails")
    func codesFirst() async throws {
        let source = FakeSource()
        source.add([
            note("sms", app: "com.apple.MobileSMS", title: "106900", body: "【某某云】您的验证码为 482913", at: start.addingTimeInterval(1)),
            note("chat", body: "明天交方案吗？", at: start.addingTimeInterval(2)),
        ])
        // The model fails once, then also reports the code, which must not be duplicated.
        let provider = StubProvider([.failure(TestError()),
                                     .success(#"{"actions":[{"sources":[1],"summary":"验证码 482913","kind":"code"}]}"#)])
        let pipeline = makePipeline(source)
        let recorder = Recorder()

        await #expect(throws: TestError.self) {
            try await pipeline.run(extractor: ActionExtractor(provider: provider)) { await recorder.record($0) }
        }
        #expect(await recorder.items.map(\.verificationCode) == ["482913"])

        try await pipeline.run(extractor: ActionExtractor(provider: provider)) { await recorder.record($0) }
        #expect(await recorder.items.count == 1)
    }

    @Test("persists progress across instances")
    func persistsState() async throws {
        let store = JSONFileStore<PipelineState>(url: temporaryDirectory().appendingPathComponent("state.json"))
        let source = FakeSource()
        source.add([note("1", body: "请审批", at: start.addingTimeInterval(5))])
        let provider = StubProvider(always: #"{"actions":[]}"#)

        try await makePipeline(source, store: store).run(extractor: ActionExtractor(provider: provider)) { _ in }
        try await makePipeline(source, store: store).run(extractor: ActionExtractor(provider: provider)) { _ in }

        #expect(provider.receivedRequests.count == 1)
        #expect(store.load()?.cursor == start.addingTimeInterval(5))
    }

    @Test("reports access errors from the source")
    func accessDenied() async {
        let pipeline = makePipeline(DeniedSource())
        await #expect(throws: NotificationSourceError.accessDenied) {
            try await pipeline.run(extractor: ActionExtractor(provider: StubProvider(always: ""))) { _ in }
        }
    }

    @Test("detects source changes")
    func changes() async {
        let source = FakeSource()
        let pipeline = makePipeline(source)
        #expect(await pipeline.hasChanges())
        #expect(await !pipeline.hasChanges())
        source.add([note("1", body: "x", at: start)])
        #expect(await pipeline.hasChanges())
    }
}

@Suite("Pipeline activity")
struct PipelineActivityTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    actor Log {
        var records: [ActivityRecord] = []
        func record(_ event: PipelineEvent) {
            if case .activity(let new) = event { records += new }
        }
    }

    @Test("records what happened to every notification")
    func recordsOutcomes() async throws {
        let source = FakeSource()
        source.add([
            note("muted", app: "com.tencent.xinwechat", title: "资料群", body: "张三: 大家填一下", at: start.addingTimeInterval(1)),
            note("empty", title: "", body: " ", at: start.addingTimeInterval(2)),
            note("others", app: "com.tencent.xinwechat", title: "项目群", body: "黄总: @李四 你安排下", at: start.addingTimeInterval(3)),
            note("boss", app: "com.tencent.xinwechat", title: "王总", body: "报价单发我", at: start.addingTimeInterval(4)),
            note("code", app: "com.apple.MobileSMS", title: "106900", body: "【某某云】您的验证码为 482913", at: start.addingTimeInterval(5)),
            note("news", app: "com.sina.weibo", title: "热搜", body: "某地发生地震", at: start.addingTimeInterval(6)),
            note("chat", app: "com.tencent.xinwechat", title: "朋友", body: "哈哈哈", at: start.addingTimeInterval(7)),
        ])
        // Indexes in the prompt skip the muted, empty and @others notifications: boss=1.
        let extractor = ActionExtractor(provider: StubProvider(always: #"{"actions":[{"sources":[1],"summary":"发报价单","kind":"task"}]}"#),
                                        userNames: ["小明"])
        // The curator never sees chats or codes, so the weibo notification is its only candidate.
        let curator = NewsCurator(provider: StubProvider(always: #"{"news":[{"sources":[1],"headline":"某地发生地震","category":"社会"}]}"#))
        let filter = NotificationFilter(mutedConversations: [ConversationKey(appID: "com.tencent.xinwechat", title: "资料群")])
        let log = Log()

        try await NotificationPipeline(source: source, stateStore: nil, now: start)
            .run(extractor: extractor, curator: curator, filter: filter) { await log.record($0) }

        let outcomes = Dictionary(uniqueKeysWithValues: await log.records.map { ($0.id, $0.outcome) })
        #expect(outcomes["muted"] == .skipped(.mutedConversation))
        #expect(outcomes["empty"] == .skipped(.empty))
        #expect(outcomes["others"] == .skipped(.mentionsOthers))
        #expect(outcomes["boss"] == .item(kind: .task, summary: "发报价单"))
        #expect(outcomes["code"] == .item(kind: .code, summary: "验证码 482913（某某云）"))
        #expect(outcomes["news"] == .news(headline: "某地发生地震"))
        // One-to-one chats are always shown, even small talk the model passed over.
        #expect(outcomes["chat"] == .item(kind: .notice, summary: "哈哈哈"))
        #expect(await log.records.count == 7)
    }

    @Test("keeps the newest records within a day and a size limit")
    func merging() {
        let now = start
        func record(_ id: String, minutesAgo: Double) -> ActivityRecord {
            ActivityRecord(notification: note(id, body: "x", at: now.addingTimeInterval(-minutesAgo * 60)), outcome: .skipped(.notActionable))
        }
        let merged = [record("old", minutesAgo: 60 * 25), record("a", minutesAgo: 5)]
            .merging([record("b", minutesAgo: 1), record("a", minutesAgo: 5)], now: now)
        #expect(merged.map(\.id) == ["b", "a"])
        #expect([].merging((0..<10).map { record("\($0)", minutesAgo: Double($0)) }, now: now, limit: 3).map(\.id) == ["0", "1", "2"])
    }
}
