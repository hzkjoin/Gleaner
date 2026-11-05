import Foundation
import Testing
@testable import GleanerCore

@Suite struct IrrelevantFeedbackTests {
    private func example(_ summary: String, app: String = "com.sankuai.meituan", conversation: String = "美团",
                         excerpt: String, suggested: Bool = false) -> IrrelevantExample {
        IrrelevantExample(summary: summary, appID: app, conversation: conversation, excerpt: excerpt,
                          suggested: suggested)
    }

    private let appName: @Sendable (String) -> String = { $0 == "com.sankuai.meituan" ? "美团" : "微信" }

    @Test func candidatesNeedThreeFromTheLatestApp() {
        var examples = [
            example("领券", excerpt: "你有一张优惠券待领取"),
            example("群公告", app: "com.tencent.xinwechat", conversation: "读书会", excerpt: "本周停更"),
            example("满减", excerpt: "满 30 减 10 优惠券已到账"),
        ]
        #expect(examples.ruleCandidates() == nil)
        examples.append(example("红包", excerpt: "优惠券红包即将过期"))
        #expect(examples.ruleCandidates()?.count == 3)
        // Offered once already: no new suggestion until more arrive.
        examples = examples.map { var e = $0; e.suggested = true; return e }
        #expect(examples.ruleCandidates() == nil)
    }

    @Test func acceptsARuleThatCoversEveryExample() {
        let examples = [
            example("领券", excerpt: "你有一张优惠券待领取"),
            example("满减", excerpt: "满 30 减 10 优惠券已到账"),
            example("红包", excerpt: "优惠券红包即将过期"),
        ]
        let output = #"{"text":"美团的优惠券消息都忽略","app":"美团","conversation":"","keyword":"优惠券"}"#
        let rule = RuleSuggester.rule(from: output, covering: examples, appName: appName)
        #expect(rule?.action == .ignore)
        #expect(rule?.keyword == "优惠券")
        #expect(rule?.text == "美团的优惠券消息都忽略")
    }

    @Test func rejectsRulesThatAreTooBroadOrMissExamples() {
        let examples = [
            example("领券", excerpt: "你有一张优惠券待领取"),
            example("外卖", excerpt: "骑手已取餐"),
            example("红包", excerpt: "优惠券红包即将过期"),
        ]
        let missing = #"{"text":"优惠券都忽略","app":"美团","conversation":"","keyword":"优惠券"}"#
        #expect(RuleSuggester.rule(from: missing, covering: examples, appName: appName) == nil)
        let everything = #"{"text":"都忽略","app":"","conversation":"","keyword":""}"#
        #expect(RuleSuggester.rule(from: everything, covering: examples, appName: appName) == nil)
        #expect(RuleSuggester.rule(from: "不是 JSON", covering: examples, appName: appName) == nil)
    }

    @Test func suggesterSendsAppNamesAndMessages() async throws {
        let provider = StubProvider([.success(#"{"text":"美团消息都忽略","app":"美团","conversation":"","keyword":""}"#)])
        let suggester = RuleSuggester(provider: provider, appName: appName)
        let rule = try await suggester.suggest(from: [example("领券", excerpt: "你有一张优惠券待领取")])
        #expect(rule?.app == "美团")
        let user = try #require(provider.receivedRequests.first?.user)
        #expect(user.contains("应用：美团"))
        #expect(user.contains("你有一张优惠券待领取"))
    }

    @Test func readsLegacyStringExamples() throws {
        struct Holder: Decodable {
            let examples: [IrrelevantExample]
            enum CodingKeys: String, CodingKey { case examples }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                examples = IrrelevantExample.decodeList(from: c, forKey: .examples)
            }
        }
        let legacy = try JSONDecoder().decode(Holder.self, from: Data(#"{"examples":["领券（美团）"]}"#.utf8))
        #expect(legacy.examples.first?.promptLine == "领券（美团）")
        #expect(legacy.examples.first?.suggested == true)

        let current = [example("领券", excerpt: "x")]
        let data = try JSONEncoder().encode(["examples": current])
        #expect(try JSONDecoder().decode(Holder.self, from: data).examples == current)
    }
}
