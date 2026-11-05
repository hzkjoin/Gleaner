import Foundation
import Testing
@testable import GleanerCore

struct ContextBudgetTests {
    @Test func oneFileGetsItsWholeShare() {
        #expect(ContextBudget.allocate([20_000], total: 38_000) == [20_000])
    }

    @Test func filesShareEvenly() {
        #expect(ContextBudget.allocate([20_000, 20_000, 20_000], total: 30_000) == [10_000, 10_000, 10_000])
    }

    @Test func shortFilesLeaveRoomForLongOnes() {
        #expect(ContextBudget.allocate([20_000, 1_000, 20_000], total: 30_000) == [14_500, 1_000, 14_500])
    }

    @Test func budgetFollowsContextLength() {
        #expect(ContextBudget(contextTokens: 32_000).attachments == 9_600)
        #expect(ContextBudget(contextTokens: 1_000_000).attachments == 60_000)
    }

    @Test func oldestPreamblesGoFirstWhenTooLong() {
        let file = String(repeating: "字", count: 5_000)
        let earlier = [ChatTurn(question: "一", answer: "答", preamble: file),
                       ChatTurn(question: "二", answer: "答", preamble: file)]
        let current = ChatTurn(question: "三")
        let fits = Assistant.fit(earlier, current: current, context: "", limit: 20_000)
        #expect(fits == earlier.map(\.message))
        let trimmed = Assistant.fit(earlier, current: current, context: "", limit: 8_000)
        #expect(trimmed[0] == earlier[0].shortMessage)
        #expect(trimmed[1] == earlier[1].message)
    }

    @Test func partialFilesDecodeFromOlderTurns() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","question":"问"}"#
        let turn = try JSONDecoder().decode(ChatTurn.self, from: Data(old.utf8))
        #expect(turn.partialFiles.isEmpty)
    }

    @Test func unreadableTypesAreNotListed() {
        #expect(ReadableFileTypes.contains(URL(fileURLWithPath: "/a/报告.PDF")))
        #expect(!ReadableFileTypes.contains(URL(fileURLWithPath: "/a/安装包.dmg")))
        #expect(!ReadableFileTypes.contains(URL(fileURLWithPath: "/a/压缩包.zip")))
    }
}
