import Foundation
import Testing
@testable import GleanerCore

struct FilePagingTests {
    /// A document of `count` sections, each opening with a heading.
    private func longText(sections count: Int) -> String {
        (1...count).map { index in
            "第\(index)章 主题\(index)\n" + String(repeating: "正文内容第\(index)章。", count: 900)
        }.joined(separator: "\n")
    }

    private func collect(_ stream: AsyncThrowingStream<Assistant.Event, Error>) async throws -> [Assistant.Event] {
        var events: [Assistant.Event] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func cutsAtLinesAndKeepsEverything() {
        let text = longText(sections: 5)
        let document = DocumentSections(text: text)
        #expect(document.count >= 5)
        #expect(document.sections.allSatisfy { $0.count <= DocumentSections.size })
        #expect(document.sections.joined(separator: "\n") == text)
    }

    @Test func cutsVeryLongLines() {
        let document = DocumentSections(text: String(repeating: "字", count: 20_000), size: 8_000)
        #expect(document.sections.map(\.count) == [8_000, 8_000, 4_000])
    }

    @Test func outlineUsesHeadings() {
        let document = DocumentSections(text: longText(sections: 3))
        #expect(document.outline.hasPrefix("1. 第1章 主题1"))
    }

    @Test func smallFilesGoWhole() {
        let (attachment, delivery) = Assistant.fileAttachment(title: "a.txt", text: "短文", extractionCut: false,
                                                              share: 1_000, canPage: true)
        #expect(delivery == .whole)
        #expect(attachment.text == "短文")
    }

    @Test func longFilesArePagedWithOutline() {
        let text = longText(sections: 6)
        let (attachment, delivery) = Assistant.fileAttachment(title: "报告.pdf", text: text, extractionCut: false,
                                                              share: 20_000, canPage: true)
        let count = DocumentSections(text: text).count
        #expect(delivery == .paged(sections: count))
        #expect(attachment.text.contains("共 \(count) 段"))
        #expect(attachment.text.contains("read_file"))
        #expect(attachment.text.contains("〔第 1 段〕"))
        #expect(!attachment.text.contains("〔第 3 段〕"))
        #expect(attachment.text.count < 20_000 + 2_000)
    }

    @Test func withoutToolsLongFilesAreCut() {
        let (attachment, delivery) = Assistant.fileAttachment(title: "报告.pdf", text: longText(sections: 6),
                                                              extractionCut: false, share: 5_000, canPage: false)
        #expect(delivery == .truncated(characters: 5_000))
        #expect(attachment.truncated)
    }

    @Test func readToolFindsSectionsAndRefuses() {
        let files = ["报告.pdf": DocumentSections(text: longText(sections: 6))]
        func call(_ arguments: String) -> ToolCall { ToolCall(id: "c", name: "read_file", arguments: arguments) }
        #expect(Assistant.read(call(#"{"file":"报告.pdf","section":3}"#), in: files, readsSoFar: 0, room: 100_000)
            .hasPrefix("〔报告.pdf 第 3 段"))
        // Partial names and numbers written as text still work.
        #expect(Assistant.read(call(#"{"file":"报告","section":"2"}"#), in: files, readsSoFar: 0, room: 100_000)
            .hasPrefix("〔报告.pdf 第 2 段"))
        #expect(Assistant.read(call(#"{"file":"报告.pdf","section":99}"#), in: files, readsSoFar: 0, room: 100_000).hasPrefix("（"))
        #expect(Assistant.read(call(#"{"file":"报告.pdf","section":2}"#), in: files, readsSoFar: 4, room: 100_000).hasPrefix("（"))
        #expect(Assistant.read(call(#"{"file":"报告.pdf","section":2}"#), in: files, readsSoFar: 0, room: 100).hasPrefix("（"))
    }

    @Test func modelReadsASectionThenAnswers() async throws {
        let document = DocumentSections(text: longText(sections: 6))
        let provider = ScriptedChatProvider([
            [.toolCalls([ToolCall(id: "c1", name: "read_file", arguments: #"{"file":"报告.pdf","section":4}"#)], reasoning: nil)],
            [.text("第四章讲的是主题4")],
        ])
        let assistant = Assistant(provider: provider, userNames: [])
        let events = try await collect(assistant.converse(ChatTurn(question: "第四章讲什么"), history: [], context: "系统",
                                                          search: nil, files: ["报告.pdf": document]))
        #expect(events.contains(.reading("报告.pdf 第 4 段")))
        #expect(events.contains(.text("第四章讲的是主题4")))
        #expect(provider.calls.count == 2)
        #expect(provider.calls[0].toolCount == 2)
        let tool = provider.calls[1].messages.last
        #expect(tool?.role == .tool)
        #expect(tool?.content.hasSuffix(document.section(4)!) == true)
    }

    @Test func searchReturnsNumberedLinesWithContext() {
        let text = "第1章 概况\n背景说明\n采购预算为 368 万元\n由周敏审批\n其他\n其他\n其他\n预算执行情况良好"
        let document = DocumentSections(text: text)
        let (lines, total) = document.search(["预算"])
        #expect(total == 2)
        #expect(lines.map(\.line) == [2, 3, 4, 7, 8])
        #expect(lines.first { $0.line == 3 }?.text == "采购预算为 368 万元")
        #expect(lines.allSatisfy { $0.section == 1 })
    }

    @Test func searchToolListsMatchesAndSections() {
        let files = ["报告.pdf": DocumentSections(text: longText(sections: 6) + "\n附录\n审批人：周敏")]
        func call(_ arguments: String) -> ToolCall { ToolCall(id: "c", name: "search_file", arguments: arguments) }
        let found = Assistant.searchFiles(call(#"{"keywords":"审批人"}"#), in: files, searchesSoFar: 0)
        #expect(found.hasPrefix("〔报告.pdf〕共 1 处"))
        #expect(found.contains("审批人：周敏"))
        #expect(found.contains("段）"))
        #expect(Assistant.searchFiles(call(#"{"keywords":"不存在的词"}"#), in: files, searchesSoFar: 0).hasPrefix("（没有找到"))
        #expect(Assistant.searchFiles(call(#"{"keywords":"审批人"}"#), in: files, searchesSoFar: 4).hasPrefix("（这次已搜索"))
        // Many matches are capped.
        let clauses = ["合同.docx": DocumentSections(text: (1...40).map { "第 \($0) 条款" }.joined(separator: "\n"))]
        let many = Assistant.searchFiles(call(#"{"file":"合同","keywords":"条款"}"#), in: clauses, searchesSoFar: 0)
        #expect(many.contains("只列出前 30 处"))
    }

    @Test func searchResultsShrinkToTheRoomLeft() {
        let files = ["合同.docx": DocumentSections(text: (1...40).map { "第 \($0) 条款，" + String(repeating: "内容", count: 40) }
            .joined(separator: "\n"))]
        let call = ToolCall(id: "c", name: "search_file", arguments: #"{"keywords":"条款"}"#)
        let full = Assistant.searchFiles(call, in: files, searchesSoFar: 0)
        let small = Assistant.searchFiles(call, in: files, searchesSoFar: 0, room: 1_000)
        #expect(small.count <= 1_000)
        #expect(small.count < full.count)
        #expect(small.contains("结果过多，只列出前"))
        #expect(Assistant.searchFiles(call, in: files, searchesSoFar: 0, room: 100) == Assistant.contextFull)
    }

    @Test func readRefusesWhenTheSectionDoesNotFit() {
        let files = ["报告.pdf": DocumentSections(text: longText(sections: 3))]
        let call = ToolCall(id: "c", name: "read_file", arguments: #"{"file":"报告.pdf","section":1}"#)
        #expect(Assistant.read(call, in: files, readsSoFar: 0, room: 2_000) == Assistant.contextFull)
    }

    @Test func webResultsDropToFit() {
        let results = (1...5).map { WebResult(title: "标题\($0)", url: "u", site: "站", date: nil, summary: String(repeating: "摘", count: 300)) }
        let fitted = Assistant.describe(results, room: 700)
        #expect(fitted != nil && fitted!.count <= 700)
        #expect(fitted?.contains("标题1") == true && fitted?.contains("标题3") == false)
        #expect(Assistant.describe(results, room: 50) == nil)
    }

    @Test func toolsStopWhenTheConversationIsFull() async throws {
        let document = DocumentSections(text: longText(sections: 6))
        let provider = ScriptedChatProvider([
            [.toolCalls([ToolCall(id: "c1", name: "read_file", arguments: #"{"file":"报告.pdf","section":4}"#)], reasoning: nil)],
            [.text("根据已有内容回答")],
        ])
        let assistant = Assistant(provider: provider, userNames: [])
        let events = try await collect(assistant.converse(ChatTurn(question: "第四章讲什么"), history: [], context: "系统",
                                                          search: nil, budget: ContextBudget(attachments: 1_000, conversation: 3_000),
                                                          files: ["报告.pdf": document]))
        #expect(!events.contains { if case .reading = $0 { return true } else { return false } })
        #expect(provider.calls[1].messages.last?.content == Assistant.contextFull)
    }

    @Test func longLinesAreCutAroundTheKeyword() {
        let line = String(repeating: "甲", count: 500) + "关键" + String(repeating: "乙", count: 500)
        let excerpt = DocumentSections.excerpt(line, around: ["关键"])
        #expect(excerpt.contains("关键"))
        #expect(excerpt.count <= 202)
    }

    @Test func contextLengthCanBeSet() {
        var configuration = ProviderPreset.all[2].configuration
        #expect(configuration.contextTokens == 256_000)
        #expect(ProviderPreset.all[3].configuration.contextTokens == 128_000)
        configuration.contextK = 1_000
        #expect(configuration.contextTokens == 1_000_000)
        #expect(configuration.contextBudget.attachments == 60_000)
    }

    @Test func savedConfigurationsWithoutContextLengthDecode() throws {
        let json = #"{"apiProtocol":"openai","baseURL":"https://api.deepseek.com","model":"deepseek-flash"}"#
        let configuration = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(json.utf8))
        #expect(configuration.contextK == nil)
    }

    @Test func longFilesAreSummarizedInParts() async throws {
        final class Recorder: LLMProvider, @unchecked Sendable {
            let lock = NSLock()
            var requests: [CompletionRequest] = []
            func complete(_ request: CompletionRequest) async throws -> String {
                lock.withLock { requests.append(request) }
                return "- 要点"
            }
            func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
                lock.withLock { requests.append(request) }
                return AsyncThrowingStream { $0.yield("- 总结"); $0.finish() }
            }
        }
        let provider = Recorder()
        let content = FileTextExtractor.Content(text: longText(sections: 6), truncated: false)
        var output = ""
        for try await piece in Assistant(provider: provider, userNames: []).summarizeFile(named: "报告.pdf", content: content,
                                                                                         partSize: 20_000) {
            output += piece
        }
        #expect(output == "- 总结")
        let parts = DocumentSections(text: content.text, size: 20_000).count
        #expect(provider.requests.count == parts + 1)
        #expect(provider.requests.last?.user.contains("【第 \(parts) 部分】") == true)
    }
}
