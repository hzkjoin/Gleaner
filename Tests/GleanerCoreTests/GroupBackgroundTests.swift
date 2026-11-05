import Foundation
import Testing
@testable import GleanerCore

struct GroupBackgroundTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let chat = ConversationKey(appID: "com.tencent.xinwechat", title: "球友群")

    func archived(_ id: String, _ body: String, minutesBefore: Double) -> ArchivedMessage {
        ArchivedMessage(id: id, appID: chat.appID, title: chat.title, body: body, date: start.addingTimeInterval(-minutesBefore * 60))
    }

    func extractor(_ provider: StubProvider, history: [ArchivedMessage]) -> ActionExtractor {
        ActionExtractor(provider: provider, userNames: ["小明"], now: { self.start }, history: { key in
            key == self.chat ? history : []
        })
    }

    @Test func groupMessagesComeWithTheirRecentChat() async throws {
        let provider = StubProvider(always: #"{"actions":[]}"#)
        let history = [archived("old", "张三: 三小时前的话", minutesBefore: 180),
                       archived("h1", "张三: 今晚谁来？", minutesBefore: 10)]
        let note = AppNotification(id: "n1", appID: chat.appID, title: chat.title, body: "李四: 我来", date: start, chatID: "1@chatroom")
        _ = try await extractor(provider, history: history).extract(from: [note])
        let prompt = try #require(provider.receivedRequests.first?.user)
        #expect(prompt.contains("聊天背景"))
        #expect(prompt.contains("张三: 今晚谁来？"))
        #expect(!prompt.contains("三小时前的话"))
        // The batch's own messages are not repeated as background.
        #expect(prompt.components(separatedBy: "李四: 我来").count == 2)
    }

    @Test func aFollowUpAfterAnAtCanNeedAReply() async throws {
        let provider = StubProvider(always: #"{"actions":[{"sources":[1],"summary":"回复周凯","kind":"reply","priority":"medium"}]}"#)
        let history = [archived("h1", "周凯（主管）在群聊中@了你", minutesBefore: 3)]
        let note = AppNotification(id: "n1", appID: chat.appID, title: chat.title, body: "周凯（主管）: ？", date: start, chatID: "1@chatroom")
        let items = try await extractor(provider, history: history).extract(from: [note])
        #expect(items.first?.kind == .reply)

        // Without the @ before it, a group message that mentions nobody stays a notice.
        let quiet = try await extractor(provider, history: [archived("h1", "张三: 哈哈", minutesBefore: 3)]).extract(from: [note])
        #expect(quiet.first?.kind == .notice)
    }

    @Test func oneToOneChatsComeWithTheirRecentChatToo() async throws {
        let provider = StubProvider(always: #"{"actions":[]}"#)
        let boss = ConversationKey(appID: "com.tencent.xinwechat", title: "周凯")
        let history = [ArchivedMessage(id: "h1", appID: boss.appID, title: boss.title, body: "只拿了单独聊的", date: start.addingTimeInterval(-60))]
        let note = AppNotification(id: "n1", appID: boss.appID, title: boss.title, body: "那是为啥？", date: start, chatID: "wxid_a")
        let extractor = ActionExtractor(provider: provider, now: { self.start }, history: { $0 == boss ? history : [] })
        _ = try await extractor.extract(from: [note])
        #expect(provider.receivedRequests.first?.user.contains("周凯: 只拿了单独聊的") == true)
    }

    @Test func everyPromptThatReadsTheRecordExplainsIt() {
        let assistant = Assistant(provider: StubProvider([]))
        #expect(assistant.summaryRequest([], conversation: "群").system.contains(RecordNote.text))
        #expect(assistant.conversationContext(messages: [], openItems: [], canSearch: false, appName: { $0 }).contains(RecordNote.text))
        #expect(ReplyPrompt.system(userNames: []).contains(RecordNote.text))
        #expect(ExtractionPrompt.system(userNames: []).contains(RecordNote.text))
    }
}
