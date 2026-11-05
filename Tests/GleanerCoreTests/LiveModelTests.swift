import Foundation
import Testing
@testable import GleanerCore

/// Runs the real prompt against a live model. Skipped unless enabled:
///
///     GLEANER_LIVE_BASE_URL=http://127.0.0.1:11434/v1 GLEANER_LIVE_MODEL=qwen3:30b-a3b scripts/swiftw test --filter Live
///
/// Optional: `GLEANER_LIVE_PROTOCOL=anthropic`, `GLEANER_LIVE_API_KEY=...`, `GLEANER_LIVE_REASONING=0`.
enum LiveModel {
    static var configuration: ProviderConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard let baseURL = env["GLEANER_LIVE_BASE_URL"], let model = env["GLEANER_LIVE_MODEL"] else { return nil }
        let apiProtocol = APIProtocol(rawValue: env["GLEANER_LIVE_PROTOCOL"] ?? "") ?? .openAICompatible
        let reasoning = env["GLEANER_LIVE_REASONING"] != "0"
        return ProviderConfiguration(apiProtocol: apiProtocol, baseURL: baseURL, model: model, reasoning: reasoning)
    }

    static var apiKey: String { ProcessInfo.processInfo.environment["GLEANER_LIVE_API_KEY"] ?? "" }
}

@Suite("Live model", .enabled(if: LiveModel.configuration != nil), .serialized)
struct LiveModelTests {
    let now = Date()

    var samples: [AppNotification] {
        [
            note("1", app: "com.tencent.weworkmac", title: "打卡", body: "11月3日打卡异常，请尽快处理", at: now.addingTimeInterval(-600)),
            note("2", app: "com.tencent.xinwechat", title: "项目群", body: "张三: 好的收到", at: now.addingTimeInterval(-500)),
            note("3", app: "com.apple.MobileSMS", title: "106900", body: "【某某云】您的验证码为 482913，5分钟内有效。", at: now.addingTimeInterval(-400)),
            note("4", app: "com.tencent.xinwechat", title: "行业交流群", body: "李四: 今天大会的新闻大家看了吗", at: now.addingTimeInterval(-300)),
            note("5", app: "com.tencent.xinwechat", title: "王总", body: "小明，报价单今天下班前发我一下", at: now.addingTimeInterval(-200)),
            note("6", app: "com.xingin.discover", title: "小红书", body: "你关注的博主发布了新笔记", at: now.addingTimeInterval(-100)),
            note("7", app: "com.tencent.xinwechat", title: "项目群", body: "黄总: @李四 @王五 你们安排一下活动资源", at: now.addingTimeInterval(-90)),
            note("8", app: "com.tencent.xinwechat", title: "项目群", body: "黄总: @小明 明天上午的评审你来主持一下", at: now.addingTimeInterval(-80)),
            note("9", app: "com.meituan.imeituan", title: "骑手给您发送了消息", body: "王师傅：您的订单已送达，如有配送问题，可先联系骑手。", at: now.addingTimeInterval(-70)),
            note("10", app: "com.tencent.xinwechat", title: "资料群", body: "赵六: 1、本季度报表按什么口径统计？ 答：按实际回款金额统计", at: now.addingTimeInterval(-60)),
            note("11", app: "com.tencent.xinwechat", title: "饭搭子群", body: "老周: 哈哈哈 好的👌", at: now.addingTimeInterval(-50)),
        ]
    }

    @Test("finds the actionable notifications and ignores the noise")
    func extractsFromSamples() async throws {
        let configuration = try #require(LiveModel.configuration)
        let extractor = ActionExtractor(
            provider: configuration.makeProvider(apiKey: LiveModel.apiKey),
            userNames: ["小明"],
            appName: { ["com.tencent.weworkmac": "企业微信", "com.tencent.xinwechat": "微信",
                        "com.apple.MobileSMS": "信息", "com.xingin.discover": "小红书"][$0] ?? $0 }
        )

        let started = Date()
        var items = try await extractor.extract(from: samples)
        // Same as the pipeline: substantive unaddressed group messages become notices by rule.
        items += GroupNoticeRule.items(in: samples, analyzer: MentionAnalyzer(userNames: ["小明"]),
                                       covered: Set(items.flatMap(\.sourceIDs)))
        let elapsed = Date().timeIntervalSince(started)

        print("⏱ \(configuration.model)\(configuration.reasoning ? "" : " (no reasoning)"): \(String(format: "%.1f", elapsed))s, \(items.count) items")
        for item in items {
            print("  [\(item.kind.rawValue)/\(item.priority.rawValue)] \(item.summary)\(item.due.isEmpty ? "" : "（截止 \(item.due)）") ← \(item.sourceTitle)")
        }

        let text = items.map(\.summary).joined(separator: " ")
        #expect(text.contains("482913"), "verification code should be surfaced")
        #expect(text.contains("打卡"), "attendance exception should be surfaced")
        #expect(text.contains("报价"), "direct request from 王总 should be surfaced")
        #expect(!items.contains { $0.sourceTitle == "小红书" }, "marketing push should be ignored")
        #expect(items.first { $0.appID == "com.meituan.imeituan" }?.kind == .notice, "personal updates should be noticed")
        #expect(items.first { $0.sourceTitle == "资料群" }?.kind == .notice, "substantive group messages should be noticed")
        #expect(!items.contains { $0.sourceTitle == "饭搭子群" }, "chit-chat should be ignored")
        #expect(!items.contains { $0.sourceExcerpt.contains("@李四") }, "messages for other people should be ignored")
        #expect(items.contains { $0.sourceExcerpt.contains("@小明") }, "messages that @mention the user should be surfaced")
        #expect(items.contains { $0.kind == .code && $0.verificationCode == "482913" })
        let boss = items.first { $0.sourceTitle == "王总" }
        #expect(boss?.kind == .reply || boss?.kind == .task, "a direct request should be a reply or task item")
    }
}

/// Reads this Mac's real forwarded iPhone notifications and prints counts per app (no content).
///
///     GLEANER_LIVE_IPHONE=1 scripts/swiftw test --filter LiveIPhoneSourceTests
@Suite("Live iPhone source", .enabled(if: ProcessInfo.processInfo.environment["GLEANER_LIVE_IPHONE"] != nil))
struct LiveIPhoneSourceTests {
    @Test("reads forwarded notifications on this Mac")
    func readsRealFiles() throws {
        let started = Date()
        let notes = try IPhoneNotificationSource().fetch(after: .distantPast)
        let elapsed = Date().timeIntervalSince(started) * 1000
        let perApp = Dictionary(grouping: notes, by: \.appID).mapValues(\.count).sorted { $0.value > $1.value }
        print("📱 \(notes.count) notifications from \(perApp.count) apps in \(Int(elapsed)) ms; unknown app: \(perApp.contains { $0.key == "iphone.unknown" })")
        for (app, count) in perApp.prefix(8) { print("   \(count)\t\(app)") }
        print("   passcodes flagged by the system: \(notes.filter(\.isOneTimePasscode).count)")
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { $0.origin == .iPhone && !$0.id.isEmpty })
    }
}

@Suite("Live news curation", .enabled(if: LiveModel.configuration != nil), .serialized)
struct LiveNewsCurationTests {
    let now = Date()

    @Test("picks news and trending topics, skips promotions and social noise")
    func curatesSamples() async throws {
        var configuration = try #require(LiveModel.configuration)
        configuration.reasoning = false
        let names = ["com.taobao.taobao4iphone": "淘宝", "com.sina.weibo": "微博", "com.dianping.dpscope": "大众点评",
                     "com.xingin.discover": "小红书", "com.usmart.global.sg.stock": "盈立"]
        let curator = NewsCurator(provider: configuration.makeProvider(apiKey: LiveModel.apiKey), appName: { names[$0] ?? $0 })
        func n(_ id: String, _ app: String, _ title: String, _ body: String) -> AppNotification {
            AppNotification(id: id, appID: app, title: title, body: body, date: now, origin: .iPhone)
        }
        let samples = [
            n("1", "com.taobao.taobao4iphone", "雷克沙DDR5内存条", "32GB×2内存套装，6000MHz频率，电脑瞬间快如闪电！【5999淘金币抵扣购买】"),
            n("2", "com.sina.weibo", "热点新闻", "港股创新药与 CXO 板块集体走强 药明系领涨 行业订单与业绩支撑市场信心"),
            n("3", "com.dianping.dpscope", "飞3000公里也要滑的雪❗️开板了", "第一波滑雪的已经抵达现场❄️可可托海开滑了，粉雪落差全拉满✨ 点开看>>"),
            n("4", "com.sina.weibo", "马天宇已删除杨幂接下来是孙怡", "马天宇今天发了条微博：“杨幂已经被删除，接下来就是孙怡了”… 视频>>"),
            n("5", "com.xingin.discover", "小红书", "林同学 赞了你的笔记"),
            n("6", "com.xingin.discover", "小红书", "你关注的博主发布了新笔记"),
            n("7", "com.usmart.global.sg.stock", "美股异动", "英伟达盘前涨超3%，市值再创新高"),
        ]
        let started = Date()
        let news = try await curator.curate(samples)
        print("📰 \(configuration.model): \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(news.count) items")
        for item in news { print("   [\(item.category.displayName)] \(item.headline)  ← \(names[item.appID] ?? item.appID)") }

        let text = news.map(\.headline).joined(separator: " ")
        #expect(text.contains("港股") || text.contains("创新药"), "market news should be kept")
        #expect(text.contains("英伟达"), "stock movement should be kept")
        #expect(text.contains("马天宇"), "trending entertainment topics should be kept")
        #expect(!news.contains { $0.appID == "com.taobao.taobao4iphone" }, "promotions should be skipped")
        #expect(!news.contains { $0.appID == "com.xingin.discover" }, "social interactions should be skipped")
        #expect(news.allSatisfy { !$0.headline.contains("点开看") && !$0.headline.contains(">>") })
    }
}

@Suite("Live rule suggestion", .enabled(if: LiveModel.configuration != nil))
struct LiveRuleSuggestionTests {
    @Test func drawsANarrowRuleFromMarkedItems() async throws {
        let configuration = try #require(LiveModel.configuration)
        let names = ["com.sankuai.meituan": "美团"]
        let suggester = RuleSuggester(provider: configuration.makeProvider(apiKey: LiveModel.apiKey),
                                      appName: { names[$0] ?? $0 })
        let examples = [
            IrrelevantExample(summary: "领取优惠券", appID: "com.sankuai.meituan", conversation: "美团",
                              excerpt: "你有 3 张优惠券即将过期，快去使用吧"),
            IrrelevantExample(summary: "神券节活动", appID: "com.sankuai.meituan", conversation: "美团外卖",
                              excerpt: "神券节来了！满 30 减 15 优惠券限时领取"),
            IrrelevantExample(summary: "会员红包", appID: "com.sankuai.meituan", conversation: "美团",
                              excerpt: "会员专享优惠券已到账，今日有效"),
        ]
        let rule = try #require(try await suggester.suggest(from: examples))
        print("Suggested:", rule.text, "|", rule.summary)
        // Narrower than the whole app, so the rider's delivery messages still come through.
        let delivery = AppNotification(id: "d", appID: "com.sankuai.meituan", title: "骑手给您发送了消息",
                                       body: "您的订单已送达", date: Date())
        #expect(!rule.matches(delivery, appName: "美团"))
    }
}

@Suite("Live conversation", .enabled(if: LiveModel.configuration?.sharesKey(with: .deepseek) == true))
struct LiveConversationTests {
    @Test func searchesForCurrentInformation() async throws {
        let configuration = try #require(LiveModel.configuration)
        let assistant = Assistant(provider: configuration.makeProvider(apiKey: LiveModel.apiKey))
        var searches: [String] = []
        var answer = ""
        let start = Date()
        for try await event in assistant.converse("今天上证指数收盘多少点？", history: [], messages: [], openItems: [],
                                                  search: configuration.makeWebSearch(channel: .deepseek, channelKey: "", modelKey: LiveModel.apiKey),
                                                  appName: { $0 }) {
            switch event {
            case .searching(let query): searches.append(query)
            case .text(let piece): answer += piece
            }
        }
        print("Searches:", searches, "seconds:", Int(Date().timeIntervalSince(start)))
        print("Answer:", Assistant.clean(answer))
        #expect(!searches.isEmpty)
        #expect(!Assistant.clean(answer).isEmpty)
    }

    @Test func answersWithoutSearchingWhenNotNeeded() async throws {
        let configuration = try #require(LiveModel.configuration)
        let assistant = Assistant(provider: configuration.makeProvider(apiKey: LiveModel.apiKey))
        var searches = 0
        for try await event in assistant.converse("把“收到”翻译成英文", history: [], messages: [], openItems: [],
                                                  search: configuration.makeWebSearch(channel: .deepseek, channelKey: "", modelKey: LiveModel.apiKey),
                                                  appName: { $0 }) {
            if case .searching = event { searches += 1 }
        }
        #expect(searches == 0)
    }
}

/// Reads the local Mail library. Prints counts only. Enable with `GLEANER_LIVE_MAIL=1`.
@Suite("Live Mail source", .enabled(if: ProcessInfo.processInfo.environment["GLEANER_LIVE_MAIL"] != nil))
struct LiveMailSourceTests {
    @Test func readsRecentInboxMail() throws {
        let notes = try MailSource().fetch(after: Date().addingTimeInterval(-3 * 86_400))
        let withBody = notes.filter { $0.body.count > ($0.subtitle.count + 1) }
        let codes = notes.compactMap { VerificationCodeDetector.item(for: $0) }.count
        print("Mail: \(notes.count) inbox messages in 3 days, \(withBody.count) with body text, average \(notes.isEmpty ? 0 : notes.map(\.body.count).reduce(0, +) / notes.count) chars, \(codes) codes")
        #expect(!notes.isEmpty)
    }
}

/// Parses one local .emlx file. Prints lengths and whether a code was found, never content.
/// Enable with `GLEANER_LIVE_EMLX=/path/to/file.emlx`.
@Suite("Live emlx", .enabled(if: ProcessInfo.processInfo.environment["GLEANER_LIVE_EMLX"] != nil))
struct LiveEMLXTests {
    @Test func parses() throws {
        let path = ProcessInfo.processInfo.environment["GLEANER_LIVE_EMLX"]!
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = MailMessageText.text(fromEMLX: data) ?? ""
        let note = AppNotification(id: "x", appID: MailSource.appID, title: "t", body: text, date: Date())
        let code = VerificationCodeDetector.item(for: note)?.verificationCode
        print("emlx: \(data.count) bytes, text \(text.count) chars, code found: \(code != nil) (\(code?.count ?? 0) digits)")
    }
}
