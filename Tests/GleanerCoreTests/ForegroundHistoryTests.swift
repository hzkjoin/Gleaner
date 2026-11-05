import Foundation
import Testing
@testable import GleanerCore

@Suite struct ForegroundHistoryTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    @Test func recordsSpansPerApp() {
        var history = ForegroundHistory()
        history.activate("com.tencent.xinWeChat", at: at(0))
        history.activate("com.tencent.xinwechat", at: at(5))   // same app, ignored
        history.activate("com.apple.Safari", at: at(10))
        history.activate("com.tencent.xinWeChat", at: at(10.5))
        history.activate(nil, at: at(20))                      // sleep
        #expect(history.spans.count == 3)
        // Spans under a minute apart merge.
        #expect(history.gaps(for: "com.tencent.xinwechat", from: at(-60), to: at(60))
                == [DateInterval(start: at(0), end: at(20))])
    }

    @Test func clipsToTheWindowAndKeepsOpenSpans() {
        var history = ForegroundHistory()
        history.activate("a", at: at(0))
        history.activate("b", at: at(30))
        history.activate("a", at: at(40))
        #expect(history.gaps(for: "a", from: at(10), to: at(50))
                == [DateInterval(start: at(10), end: at(30)), DateInterval(start: at(40), end: at(50))])
        #expect(history.gaps(for: "c", from: at(0), to: at(50)).isEmpty)
    }

    @Test func dropsOldSpans() {
        var history = ForegroundHistory()
        history.activate("a", at: at(0))
        history.activate("b", at: at(1))
        history.activate("a", at: at(60 * 24 * 8))
        #expect(history.spans.map(\.appID) == ["b", "a"])
    }

    @Test func describesGapsForTheModel() {
        #expect(ForegroundHistory.describe([], appName: "微信") == nil)
        let line = ForegroundHistory.describe([DateInterval(start: Date().addingTimeInterval(-600), duration: 300)], appName: "微信")
        #expect(line?.hasPrefix("微信：") == true)
        #expect(line?.contains("–") == true)
    }

    @Test func promptsMentionGaps() {
        let assistant = Assistant(provider: StubProvider([]))
        let request = assistant.summaryRequest([], conversation: "项目群", gaps: ["微信：09:12–09:40"])
        #expect(request.system.contains("09:12–09:40"))
        #expect(request.system.contains("部分时段记录缺失"))
        #expect(!assistant.summaryRequest([], conversation: "项目群").system.contains("记录可能不全"))
    }
}
