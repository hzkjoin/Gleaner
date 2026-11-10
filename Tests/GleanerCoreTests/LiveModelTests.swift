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
        let context = assistant.conversationContext(messages: [], openItems: [], canSearch: true, appName: { $0 })
        for try await event in assistant.converse(ChatTurn(question: "今天上证指数收盘多少点？"), history: [], context: context,
                                                  search: configuration.makeWebSearch(channel: .deepseek, channelKey: "", modelKey: LiveModel.apiKey)) {
            switch event {
            case .searching(let query): searches.append(query)
            case .text(let piece): answer += piece
            case .usage, .reading: break
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
        let context = assistant.conversationContext(messages: [], openItems: [], canSearch: true, appName: { $0 })
        for try await event in assistant.converse(ChatTurn(question: "把“收到”翻译成英文"), history: [], context: context,
                                                  search: configuration.makeWebSearch(channel: .deepseek, channelKey: "", modelKey: LiveModel.apiKey)) {
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

@Suite("Live file summary", .enabled(if: LiveModel.configuration != nil))
struct LiveFileSummaryTests {
    @Test func summarizesAReceivedFile() async throws {
        let configuration = try #require(LiveModel.configuration)
        let content = FileTextExtractor.Content(text: """
        关于开展 2026 年第四季度资料报送工作的通知
        各部门：
        请于 11 月 20 日前通过系统提交第四季度经营数据，包括营业收入、回款金额、在途合同。
        逾期未报送的部门将在月度会议上通报。
        联系人：综合部 李明 010-12345678
        """, truncated: false)
        var text = ""
        for try await piece in Assistant(provider: configuration.makeProvider(apiKey: LiveModel.apiKey), userNames: ["小明"])
            .summarizeFile(named: "资料报送通知.docx", content: content) { text += piece }
        let summary = Assistant.clean(text)
        print("Summary:\n\(summary)")
        #expect(summary.contains("11 月 20 日") || summary.contains("11月20日"))
        #expect(!summary.contains("·"))
    }
}

@Suite("Live prompt cache", .enabled(if: LiveModel.configuration?.apiProtocol == .openAICompatible))
struct LivePromptCacheTests {
    @Test func followUpsHitTheCache() async throws {
        let configuration = try #require(LiveModel.configuration)
        let assistant = Assistant(provider: configuration.makeProvider(apiKey: LiveModel.apiKey))
        let messages = (0..<120).map { index in
            ArchivedMessage(id: "\(index)", appID: "com.tencent.xinwechat", title: index % 2 == 0 ? "项目群" : "王总",
                            body: "第 \(index) 条：关于第四季度报价和交付排期的讨论，涉及合同条款与回款节点。", date: Date())
        }
        let context = assistant.conversationContext(messages: messages, openItems: [], canSearch: false, appName: { _ in "微信" })

        func ask(_ turn: ChatTurn, after history: [ChatTurn]) async throws -> (String, PromptUsage?) {
            var answer = ""
            var usage: PromptUsage?
            for try await event in assistant.converse(turn, history: history, context: context, search: nil) {
                if case .text(let piece) = event { answer += piece }
                if case .usage(let value) = event { usage = value }
            }
            return (Assistant.clean(answer), usage)
        }
        var first = ChatTurn(question: "王总最近在讨论什么？一句话")
        let (answer, usage1) = try await ask(first, after: [])
        first.answer = answer
        try await Task.sleep(for: .seconds(4))  // the cache is built shortly after a request
        let (_, usage2) = try await ask(ChatTurn(question: "涉及哪些条款？一句话"), after: [first])
        print("Turn 1: \(usage1.map { "\($0.promptTokens) prompt, \($0.cachedTokens) cached" } ?? "no usage")")
        print("Turn 2: \(usage2.map { "\($0.promptTokens) prompt, \($0.cachedTokens) cached" } ?? "no usage")")
        #expect((usage2?.cachedTokens ?? 0) > (usage2?.promptTokens ?? 0) / 2)
    }
}

@Suite("Live schedule suggestions", .enabled(if: LiveModel.configuration != nil))
struct LiveScheduleTests {
    @Test func picksWhatIsWorthScheduling() async throws {
        let configuration = try #require(LiveModel.configuration)
        let now = Date()
        func item(_ summary: String, due: String = "", excerpt: String, from: String) -> ActionItem {
            ActionItem(summary: summary, due: due, kind: .task, appID: "com.tencent.xinwechat", sourceTitle: from,
                       sourceExcerpt: excerpt, notificationDate: now)
        }
        let items = [
            item("参加明天下午的项目评审", due: "明天 15:00", excerpt: "明天下午三点在 3 楼会议室评审方案，大概一个半小时", from: "项目群"),
            item("提交第四季度报送数据", due: "11 月 20 日前", excerpt: "请于 11 月 20 日前通过系统提交第四季度经营数据", from: "综合部"),
            item("看一下新方案", excerpt: "有空看下新方案，提提意见", from: "王总"),
            item("培训：11日、12日中午有课", due: "11日、12日中午", excerpt: "培训提醒：11 月 11 日（周三）中午 12:30，第三课：销售流程的合规性；11 月 12 日（周四）中午 12:30，第四课：适当性义务", from: "培训群"),
        ]
        let result = try await ScheduleSuggester(provider: configuration.makeProvider(apiKey: LiveModel.apiKey),
                                                 appName: { _ in "微信" }).suggest(for: items, now: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        for (index, item) in items.enumerated() {
            if let found = result[item.id] {
                for s in found {
                    print("\(index + 1). \(s.kind.rawValue) \(s.title) \(formatter.string(from: s.start))–\(formatter.string(from: s.effectiveEnd)) allDay=\(s.allDay) 地点=\(s.location)")
                }
            } else {
                print("\(index + 1). not worth")
            }
        }
        #expect(result[items[0].id]?.first?.kind == .event)
        #expect(result[items[1].id] != nil)
        #expect(result[items[2].id] == nil)
        #expect(result[items[3].id]?.count == 2)
    }
}

extension LiveMailSourceTests {
    @Test func recentMailCanBeOpened() throws {
        let notes = try MailSource().fetch(after: Date().addingTimeInterval(-3 * 86_400))
        let source = MailSource()
        let rows = notes.compactMap { MailSource.rowID(fromNotificationID: $0.id) }
        let linked = rows.filter { source.messageURL(forRowID: $0) != nil }
        let located = rows.filter { source.location(forRowID: $0) != nil }
        print("Mail: \(linked.count) of \(rows.count) open by link; all located for scripting: \(located.count == rows.count)")
        #expect(located.count == rows.count)
    }
}

@Suite("Live mail codes", .enabled(if: LiveModel.configuration != nil))
struct LiveMailCodeTests {
    @Test func modelTellsCodesFromStatements() async throws {
        let configuration = try #require(LiveModel.configuration)
        let now = Date()
        let code = AppNotification(id: "c", appID: "com.apple.mail", title: "示例银行", subtitle: "登录验证码",
                                   body: "登录验证码\n你的一次性验证码是 583027，10 分钟内有效。如非本人操作请致电 2345 6789。", date: now)
        let statement = AppNotification(id: "s", appID: "com.apple.mail", title: "示例银行", subtitle: "月结单已就绪",
                                        body: "你的投资账户电子月结单已准备好，请登录 App 查看。客服热线 2325 8888。我们不会以任何方式向你索取一次性密码（OTP）。",
                                        date: now)
        let items = try await ActionExtractor(provider: configuration.makeProvider(apiKey: LiveModel.apiKey), userNames: ["小明"])
            .extract(from: [code, statement])
        for item in items { print("\(item.sourceIDs) \(item.kind.rawValue) code=\(item.verificationCode ?? "-") | \(item.summary)") }
        #expect(items.first { $0.sourceIDs.contains("c") }?.verificationCode == "583027")
        #expect(items.filter { $0.sourceIDs.contains("s") }.allSatisfy { $0.kind != .code })
    }
}

@Suite("Live file paging", .enabled(if: LiveModel.configuration != nil))
struct LiveFilePagingTests {
    /// A long report whose answer sits in a section the model isn't given at first.
    @Test func readsTheSectionThatHoldsTheAnswer() async throws {
        let configuration = try #require(LiveModel.configuration)
        let filler = String(repeating: "本章介绍项目背景、团队分工与例行事项，没有具体数字。", count: 300)
        let chapters = (1...10).map { index -> String in
            let fact = index == 7 ? "本季度服务器采购预算为 368 万元，由财务部周敏负责审批。\n" : ""
            let title = index == 7 ? "采购预算" : "例行说明"
            return "第\(index)章 \(title)\n\(fact)\(filler)"
        }
        let text = chapters.joined(separator: "\n")
        let (attachment, delivery) = Assistant.fileAttachment(title: "季度报告.docx", text: text, extractionCut: false,
                                                              share: 20_000, canPage: true)
        guard case .paged = delivery else { Issue.record("expected paging"); return }
        let preamble = Assistant.preamble(attachments: [attachment], appName: { $0 })
        let assistant = Assistant(provider: configuration.makeProvider(apiKey: LiveModel.apiKey))
        let context = assistant.conversationContext(messages: [], openItems: [], canSearch: false, appName: { $0 })
        var reads: [String] = []
        var answer = ""
        let start = Date()
        for try await event in assistant.converse(ChatTurn(question: "服务器采购预算是多少？谁审批？", preamble: preamble),
                                                  history: [], context: context, search: nil,
                                                  files: ["季度报告.docx": DocumentSections(text: text)]) {
            switch event {
            case .reading(let label): reads.append(label)
            case .text(let piece): answer += piece
            default: break
            }
        }
        print("Reads:", reads, "seconds:", Int(Date().timeIntervalSince(start)))
        print("Answer:", Assistant.clean(answer))
        #expect(!reads.isEmpty)
        #expect(answer.contains("368"))
        #expect(answer.contains("周敏"))
    }
}
