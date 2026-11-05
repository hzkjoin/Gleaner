import Foundation
import Testing
@testable import GleanerCore

@Suite("NewsCurator")
struct NewsCuratorTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("turns selected notifications into news items")
    func curates() async throws {
        let provider = StubProvider(always: #"{"news":[{"sources":[1,2],"headline":" 港股创新药板块走强 ","category":"财经"},{"sources":[9],"headline":"越界","category":"热搜"}]}"#)
        let curator = NewsCurator(provider: provider, appName: { $0 == "com.sina.weibo" ? "微博" : $0 })
        let news = try await curator.curate([
            note("1", app: "com.sina.weibo", title: "热点新闻", body: "港股创新药与CXO板块集体走强", at: date),
            AppNotification(id: "2", appID: "com.sina.weibo", title: "财经", body: "药明系领涨", date: date.addingTimeInterval(60), origin: .iPhone),
        ])

        #expect(news.map(\.headline) == ["港股创新药板块走强"])
        let item = try #require(news.first)
        #expect(item.category == .finance)
        #expect(item.origin == .iPhone && item.date == date.addingTimeInterval(60))
        #expect(item.sourceExcerpt == "港股创新药与CXO板块集体走强 / 药明系领涨")
        #expect(provider.receivedRequests.first?.user.contains("[1] 微博 | 热点新闻") == true)
    }

    @Test("never sends chat messages or verification codes")
    func skipsPersonalMessages() async throws {
        let provider = StubProvider(always: #"{"news":[]}"#)
        let news = try await NewsCurator(provider: provider).curate([
            note("1", app: "com.tencent.xinwechat", title: "项目群", body: "张三: 今天的新闻看了吗", at: date),
            note("2", app: "com.apple.MobileSMS", title: "106900", body: "【某某云】您的验证码为 482913", at: date),
            note("3", app: "com.example.bank", title: "银行", body: "您的验证码为 123456", at: date),
        ])
        #expect(news.isEmpty)
        #expect(provider.receivedRequests.isEmpty)
    }

    @Test("accepts empty answers and rejects garbage")
    func parsing() throws {
        #expect(try NewsCurator.parse(#"{"news":[]}"#).isEmpty)
        #expect(try NewsCurator.parse("{\n\n}").isEmpty)
        #expect(try NewsCurator.parse("").isEmpty)
        #expect(throws: LLMError.self) { try NewsCurator.parse("今天没有新闻") }
    }

    @Test("maps category labels", arguments: [("热搜", NewsCategory.trending), ("财经", .finance), ("tech", .tech), ("???", .other)])
    func categories(label: String, expected: NewsCategory) {
        #expect(NewsCategory(label: label) == expected)
    }
}

@Suite("News list")
struct NewsListTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ headline: String, ageMinutes: Double) -> NewsItem {
        NewsItem(headline: headline, appID: "a", sourceTitle: "", sourceExcerpt: "", date: now.addingTimeInterval(-ageMinutes * 60))
    }

    @Test("merges newest first, drops repeats and expired items, and caps the size")
    func merges() {
        let existing = [item("港股创新药板块走强", ageMinutes: 30), item("昨天的新闻", ageMinutes: 60 * 25)]
        let merged = existing.merging([item("港股创新药板块走强！", ageMinutes: 5), item("A 股收涨", ageMinutes: 1)], now: now)
        #expect(merged.map(\.headline) == ["A 股收涨", "港股创新药板块走强！"])

        let many = (0..<10).map { item("新闻\($0)", ageMinutes: Double($0)) }
        #expect([].merging(many, now: now, limit: 3).map(\.headline) == ["新闻0", "新闻1", "新闻2"])
    }
}

@Suite("Pipeline news")
struct PipelineNewsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    actor Collected {
        var news: [NewsItem] = []
        var analyzed = 0
        func record(_ event: PipelineEvent) {
            switch event {
            case .news(let items): news += items
            case .extracted(_, let count): analyzed += count
            case .analyzing, .activity: break
            }
        }
    }

    @Test("emits news after each batch, and a failing curator does not fail the batch")
    func emitsNews() async throws {
        let source = FakeSource()
        source.add([note("1", app: "com.sina.weibo", title: "热搜", body: "某地发生地震", at: start.addingTimeInterval(1))])
        let extractor = ActionExtractor(provider: StubProvider(always: #"{"actions":[]}"#))
        let pipeline = NotificationPipeline(source: source, stateStore: nil, now: start)
        let collected = Collected()

        let curator = NewsCurator(provider: StubProvider(always: #"{"news":[{"sources":[1],"headline":"某地发生地震","category":"社会"}]}"#))
        try await pipeline.run(extractor: extractor, curator: curator) { await collected.record($0) }
        #expect(await collected.news.map(\.headline) == ["某地发生地震"])

        source.add([note("2", app: "com.sina.weibo", title: "热搜", body: "另一条", at: start.addingTimeInterval(2))])
        let failing = NewsCurator(provider: StubProvider([.failure(TestError())]))
        try await pipeline.run(extractor: extractor, curator: failing) { await collected.record($0) }
        #expect(await collected.analyzed == 2)
        #expect(await collected.news.count == 1)
    }
}
