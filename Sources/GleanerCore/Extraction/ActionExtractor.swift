import Foundation

/// One action as returned by the model, before it is attached to its source notifications.
public struct ExtractedAction: Codable, Equatable, Sendable {
    /// 1-based indexes into the batch that was sent.
    public var sources: [Int]
    public var summary: String
    public var due: String?
    public var priority: String?
    public var kind: String?

    public init(sources: [Int], summary: String, due: String? = nil, priority: String? = nil, kind: String? = nil) {
        self.sources = sources
        self.summary = summary
        self.due = due
        self.priority = priority
        self.kind = kind
    }
}

/// Turns a batch of notifications into `ActionItem`s using an `LLMProvider`.
public struct ActionExtractor: Sendable {
    public var provider: LLMProvider
    public var userNames: [String]
    /// Summaries the user marked "不相关" (with their source), shown to the model as counter-examples.
    public var irrelevantExamples: [String]
    /// Drafts replies for items that came from a person; nil to skip replies.
    public var replyWriter: ReplyWriter?
    /// Maps a bundle identifier to a human-readable app name for the prompt.
    public var appName: @Sendable (String) -> String
    public var now: @Sendable () -> Date

    public init(
        provider: LLMProvider,
        userNames: [String] = [],
        irrelevantExamples: [String] = [],
        replyWriter: ReplyWriter? = nil,
        appName: @escaping @Sendable (String) -> String = { $0 },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.userNames = userNames
        self.irrelevantExamples = irrelevantExamples
        self.replyWriter = replyWriter
        self.appName = appName
        self.now = now
    }

    public func extract(from notifications: [AppNotification]) async throws -> [ActionItem] {
        // Group messages that @mention only other people are not the user's business.
        let analyzer = MentionAnalyzer(userNames: userNames)
        let relevant = notifications
            .map { (note: $0, addressee: analyzer.addressee(of: $0)) }
            .filter { $0.addressee != .others }
        let detectedCodes = VerificationCodeDetector.items(in: notifications)
        guard !relevant.isEmpty else { return detectedCodes }

        let request = CompletionRequest(
            system: ExtractionPrompt.system(userNames: userNames, irrelevantExamples: irrelevantExamples),
            user: ExtractionPrompt.user(notifications: relevant, now: now(), appName: appName),
            jsonSchema: ExtractionPrompt.schema
        )
        let actions = try await completeAndParse(request)
        let batch = relevant.map(\.note)
        var items = actions.compactMap { action -> ActionItem? in
            guard var item = Self.makeItem(from: action, batch: batch) else { return nil }
            // A group message that @mentions nobody is at most worth a look, whatever the model said.
            let sources = action.sources.filter { (1...relevant.count).contains($0) }
            if item.kind != .code, sources.allSatisfy({ relevant[$0 - 1].addressee == .nobodyInGroup }) {
                item.kind = .notice
                item.priority = .low
            }
            return item
        }
        if let replyWriter { items = await replyWriter.addReplies(to: items, userNames: userNames) }
        return Self.merge(items, detectedCodes: detectedCodes)
    }

    /// Small models occasionally return an empty or malformed object. Ask once more; if the
    /// second answer is an empty object too, treat the batch as having nothing to report
    /// rather than blocking the pipeline on it.
    private func completeAndParse(_ request: CompletionRequest) async throws -> [ExtractedAction] {
        var output = try await provider.complete(request)
        if let actions = try? Self.parse(output) { return actions }
        output = try await provider.complete(request)
        do {
            return try Self.parse(output)
        } catch {
            if Self.isEmptyObject(output) { return [] }
            throw error
        }
    }

    static func isEmptyObject(_ output: String) -> Bool {
        var text = output
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        let compact = text.filter { !$0.isWhitespace && $0 != "`" }.replacingOccurrences(of: "json", with: "")
        return compact.isEmpty || compact == "{}"
    }

    /// Adds rule-detected verification codes the model missed, and normalizes the model's code items.
    static func merge(_ items: [ActionItem], detectedCodes: [ActionItem]) -> [ActionItem] {
        var result = items
        for detected in detectedCodes {
            guard let code = detected.verificationCode else { continue }
            if let index = result.firstIndex(where: { $0.verificationCode == code || $0.summary.contains(code) }) {
                // The model found it too. Its wording may leave out the code itself, so the
                // rule-based item, which always shows the code, wins.
                result[index] = detected
            } else {
                result.append(detected)
            }
        }
        return result
    }

    /// Lenient parsing: drops any `<think>` preamble and code fences, then decodes the
    /// outermost JSON object.
    public static func parse(_ output: String) throws -> [ExtractedAction] {
        var text = output
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw LLMError.unexpectedResponse(String(output.prefix(300)))
        }
        struct Envelope: Decodable { let actions: [ExtractedAction] }
        do {
            return try JSONDecoder().decode(Envelope.self, from: Data(text[start...end].utf8)).actions
        } catch {
            throw LLMError.unexpectedResponse(String(output.prefix(300)))
        }
    }

    /// Validates an extracted action against the batch and builds an `ActionItem`.
    /// Returns nil for empty summaries or when no source index is in range.
    /// Whether `summary` names a code that appears, exactly, in the source messages.
    static func hasVerifiableCode(_ summary: String, in sources: [AppNotification]) -> Bool {
        let text = sources.map { [$0.title, $0.subtitle, $0.body].joined(separator: " ") }.joined(separator: " ")
        var rest = summary[...]
        while let range = rest.range(of: VerificationCodeDetector.codePattern, options: .regularExpression) {
            if text.contains(String(rest[range])) { return true }
            rest = rest[range.upperBound...]
        }
        return false
    }

    static func makeItem(from action: ExtractedAction, batch: [AppNotification]) -> ActionItem? {
        let sources = action.sources.filter { (1...batch.count).contains($0) }.map { batch[$0 - 1] }
        let summary = action.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latest = sources.max(by: { $0.date < $1.date }), !summary.isEmpty else { return nil }

        var kind = ActionKind(rawValue: action.kind?.lowercased() ?? "") ?? .task
        var priority = Priority(rawValue: action.priority?.lowercased() ?? "") ?? .medium
        if kind == .code && !hasVerifiableCode(summary, in: sources) {
            // A code the model wrote must be in the message as written; otherwise it isn't shown as one.
            kind = .notice
            priority = .low
        }

        let ordered = sources.sorted { $0.date < $1.date }
        var item = ActionItem(
            summary: summary,
            due: action.due?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            priority: priority,
            kind: kind,
            appID: latest.appID,
            origin: latest.origin,
            sourceTitle: latest.title,
            sourceExcerpt: ordered.map(\.body).joined(separator: " / "),
            notificationDate: latest.date,
            sourceIDs: ordered.map(\.id)
        )
        item.sourceMessages = ordered.map(\.body)
        return item
    }
}
