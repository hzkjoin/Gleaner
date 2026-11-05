import Foundation

/// One message kept for context.
public struct ArchivedMessage: Codable, Hashable, Sendable {
    public var id: String
    public var appID: String
    public var title: String
    public var body: String
    public var date: Date
    /// Sent by the user (only known for Messages).
    public var fromMe: Bool

    public init(id: String, appID: String, title: String, body: String, date: Date, fromMe: Bool = false) {
        self.id = id
        self.appID = appID
        self.title = title
        self.body = body
        self.date = date
        self.fromMe = fromMe
    }

    public init(_ note: AppNotification) {
        self.init(id: note.id, appID: note.appID, title: note.title,
                  body: note.attachmentPath != nil ? "[文件] \(note.body)" : note.body, date: note.date,
                  fromMe: note.isFromUser)
    }

    /// Conversation key with a case-insensitive app id, so notifications and Messages agree.
    public var conversation: ConversationKey { ConversationKey(appID: appID.lowercased(), title: title) }
}

/// Recent messages per conversation, kept on this Mac to give the model context.
///
/// Ordered by time within each conversation, deduplicated by id and by content (the same
/// message from two sources), pruned by age and per-conversation count. Thread-safe.
public final class ConversationArchive: @unchecked Sendable {
    public let retention: TimeInterval
    public let perConversationLimit: Int

    private let store: JSONFileStore<[ArchivedMessage]>?
    private let lock = NSLock()
    private var byConversation: [ConversationKey: [ArchivedMessage]] = [:]
    private var ids = Set<String>()

    public init(store: JSONFileStore<[ArchivedMessage]>?, retention: TimeInterval = 7 * 86_400,
                perConversationLimit: Int = 300) {
        self.store = store
        self.retention = retention
        self.perConversationLimit = perConversationLimit
        for message in store?.load() ?? [] { insert(message) }
    }

    public var isEmpty: Bool { lock.withLock { byConversation.isEmpty } }

    public func add(_ notes: [AppNotification]) {
        add(notes.filter(\.hasContent).map(ArchivedMessage.init))
    }

    public func add(_ messages: [ArchivedMessage]) {
        guard !messages.isEmpty else { return }
        lock.withLock {
            messages.forEach(insert)
            prune(now: Date())
        }
        save()
    }

    /// The last `limit` messages of a conversation, oldest first.
    public func messages(in conversation: ConversationKey, limit: Int = 30) -> [ArchivedMessage] {
        let key = ConversationKey(appID: conversation.appID.lowercased(), title: conversation.title)
        return lock.withLock { Array((byConversation[key] ?? []).suffix(limit)) }
    }

    /// Where a received file came from: the newest message announcing it ("张三: [文件] 报价单.pdf"),
    /// giving the chat (its title) and, in groups, the sender.
    public func origin(ofFileNamed name: String) -> (conversation: String, sender: String?)? {
        let marker = "[文件] \(name)"
        let message = lock.withLock {
            // The file's own record (from the download folder) has no chat; skip it.
            byConversation.values.joined().filter { !$0.title.isEmpty && $0.body.contains(marker) }.max { $0.date < $1.date }
        }
        guard let message else { return nil }
        let prefix = message.body.components(separatedBy: marker).first?.trimmingCharacters(in: .whitespaces) ?? ""
        let sender = prefix.hasSuffix(":") || prefix.hasSuffix("：") ? String(prefix.dropLast()).trimmingCharacters(in: .whitespaces) : nil
        return (message.title, sender?.isEmpty == false ? sender : nil)
    }

    /// Messages since `date` across all conversations, oldest first, at most `limit` (newest kept).
    public func recent(since date: Date, limit: Int = 400) -> [ArchivedMessage] {
        lock.withLock {
            Array(byConversation.values.joined().filter { $0.date >= date }.sorted { $0.date < $1.date }.suffix(limit))
        }
    }

    /// Messages before `date` that share words with `query`, best matches first, for questions
    /// about things older than the recent window ("上周王总说的报价").
    public func search(_ query: String, before date: Date, limit: Int = 60) -> [ArchivedMessage] {
        let terms = Self.searchTerms(query)
        guard !terms.isEmpty else { return [] }
        // Short questions need one shared term; longer ones two, so common words alone don't match.
        let required = terms.count <= 2 ? 1 : 2
        let candidates = lock.withLock { byConversation.values.flatMap { $0 }.filter { $0.date < date } }
        let scored = candidates.compactMap { message -> (ArchivedMessage, Int)? in
            let text = (message.title + " " + message.body).lowercased()
            let score = terms.filter { text.contains($0) }.count
            return score >= required ? (message, score) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
            .prefix(limit).map(\.0).sorted { $0.date < $1.date }
    }

    /// Search terms: ASCII words of two or more letters, and two-character pieces of Chinese text,
    /// without question words that would match everything.
    static func searchTerms(_ query: String) -> Set<String> {
        let stop: Set<String> = [
            "什么", "一下", "怎么", "哪些", "哪个", "是不", "不是", "有没", "没有", "上周", "昨天", "今天", "前天", "最近",
            "之前", "说的", "说了", "了吗", "多少", "是多", "那个", "这个", "一个", "我的", "给我", "帮我", "谁发", "发过",
            "有人", "关于", "时候", "现在", "本周", "这周", "上次", "情况", "提到", "告诉",
        ]
        var terms = Set<String>()
        var ascii = ""
        var chinese: [Character] = []
        func flush() {
            if ascii.count >= 2 { terms.insert(ascii) }
            ascii = ""
            if chinese.count >= 2 {
                for index in 0..<(chinese.count - 1) {
                    let pair = String(chinese[index...index + 1])
                    if !stop.contains(pair) { terms.insert(pair) }
                }
            }
            chinese = []
        }
        for character in query.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if !chinese.isEmpty { flush() }
                ascii.append(character)
            } else if character.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) {
                if !ascii.isEmpty { flush() }
                chinese.append(character)
            } else {
                flush()
            }
        }
        flush()
        return terms
    }

    public func removeAll(in conversation: ConversationKey) {
        let key = ConversationKey(appID: conversation.appID.lowercased(), title: conversation.title)
        lock.withLock {
            byConversation[key]?.forEach { ids.remove($0.id) }
            byConversation[key] = nil
        }
        save()
    }

    /// "11-04 19:40 张三: 报价单发我", one message per line, each with who said it: group
    /// messages carry their sender, the user's own are "我", and one-to-one messages (no sender
    /// in the text) are the other person's, named by the chat. Chat apps only record what others
    /// send, so a line without "我" is never the user's.
    public static func transcript(_ messages: [ArchivedMessage], includeConversation: Bool = false,
                                  appName: (String) -> String = { $0 }) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return messages.map { message in
            var line = formatter.string(from: message.date) + " "
            if includeConversation { line += "[\(appName(message.appID))，\(message.title)] " }
            let body = message.body.replacingOccurrences(of: "\n", with: " ")
            if message.fromMe {
                line += "我: "
            } else if !message.title.isEmpty,
                      body.range(of: MentionAnalyzer.groupSenderPattern, options: .regularExpression) == nil,
                      !MentionAnalyzer.saysMentionedYou(body) {
                line += "\(message.title): "
            }
            return line + body
        }.joined(separator: "\n")
    }

    // MARK: - Private (call with `lock` held)

    private func insert(_ message: ArchivedMessage) {
        guard ids.insert(message.id).inserted else { return }
        let key = message.conversation
        var list = byConversation[key] ?? []
        // The same text within five minutes is the same message seen through another source.
        if list.contains(where: { $0.body == message.body && abs($0.date.timeIntervalSince(message.date)) < 300 }) { return }
        let index = list.firstIndex { $0.date > message.date } ?? list.endIndex
        list.insert(message, at: index)
        byConversation[key] = list
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        for (key, list) in byConversation {
            let kept = Array(list.filter { $0.date >= cutoff }.suffix(perConversationLimit))
            if kept.isEmpty {
                byConversation[key] = nil
            } else if kept.count != list.count {
                byConversation[key] = kept
            }
        }
        ids = Set(byConversation.values.joined().map(\.id))
    }

    private func save() {
        let all = lock.withLock { Array(byConversation.values.joined()) }
        try? store?.save(all)
    }
}
