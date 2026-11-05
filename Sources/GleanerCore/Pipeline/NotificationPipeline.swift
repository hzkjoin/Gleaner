import Foundation

/// Progress of the pipeline, persisted between launches.
public struct PipelineState: Codable, Equatable, Sendable {
    /// Notifications delivered at or before this moment have been handled.
    public var cursor: Date
    /// Recently handled notification IDs, oldest first. Guards against reprocessing
    /// notifications that share a timestamp with the cursor.
    public var seenIDs: [String]

    public init(cursor: Date, seenIDs: [String] = []) {
        self.cursor = cursor
        self.seenIDs = seenIDs
    }
}

public enum PipelineEvent: Sendable {
    /// A batch of `count` notifications is being sent to the model.
    case analyzing(count: Int)
    /// A batch finished; `items` may be empty when nothing needed action.
    case extracted(items: [ActionItem], analyzedCount: Int)
    /// News and trending topics found in a batch, for browsing.
    case news([NewsItem])
    /// What happened to each notification handled in a run.
    case activity([ActivityRecord])
}

/// Incrementally reads new notifications from a source, filters them, and feeds them
/// to an `ActionExtractor` in batches.
public actor NotificationPipeline {
    public let batchSize: Int
    /// How far back to re-read on each run; combined with `seenIDs` so that late
    /// writes with equal timestamps are not missed.
    public let overlap: TimeInterval
    public let maxSeenIDs: Int

    private let source: NotificationSource
    private let stateStore: JSONFileStore<PipelineState>?
    private var state: PipelineState
    /// On first launch, how far back to analyze, counted from the first successful read.
    private let initialLookback: TimeInterval
    private let clock: @Sendable () -> Date
    /// No progress has been saved yet: the first read may come long after launch (access
    /// granted later), and should still only look back `initialLookback`.
    private var startsFresh: Bool
    private var seen: Set<String>
    private var lastToken: Date?
    private var isRunning = false
    /// Notifications whose verification code was already surfaced, so a retried batch does not repeat it.
    private var announcedCodeIDs: Set<String> = []
    /// Recently handled message contents, so a message arriving through a second source in a
    /// later run (an SMS seen as a notification and in Messages) is handled once.
    private var recentContents: [String: Date] = [:]
    public let duplicateWindow: TimeInterval = 300

    /// - Parameters:
    ///   - initialLookback: On first launch, how far back to analyze.
    ///   - stateStore: Where progress is persisted; `nil` keeps it in memory only.
    ///   - now: A fixed time for tests; the clock otherwise.
    public init(
        source: NotificationSource,
        stateStore: JSONFileStore<PipelineState>?,
        batchSize: Int = 40,
        initialLookback: TimeInterval = 3600,
        overlap: TimeInterval = 2,
        maxSeenIDs: Int = 5000,
        now: Date? = nil
    ) {
        self.source = source
        self.stateStore = stateStore
        self.batchSize = batchSize
        self.overlap = overlap
        self.maxSeenIDs = maxSeenIDs
        let clock: @Sendable () -> Date
        if let now { clock = { now } } else { clock = { Date() } }
        self.clock = clock
        self.initialLookback = initialLookback
        let saved = stateStore?.load()
        self.startsFresh = saved == nil
        let restored = saved ?? PipelineState(cursor: clock().addingTimeInterval(-initialLookback))
        self.state = restored
        self.seen = Set(restored.seenIDs)
    }

    public var currentState: PipelineState { state }

    /// Fills an empty archive with what the sources still hold, without analyzing or marking
    /// anything as seen.
    public func backfill(_ archive: ConversationArchive, since date: Date, filter: NotificationFilter) {
        guard let notes = try? source.fetch(after: date) else { return }
        archive.add(notes.filter { $0.hasContent && filter.allows($0) })
    }

    /// True when the source reports a change since the previous call.
    public func hasChanges() -> Bool {
        let token = source.changeToken()
        defer { lastToken = token }
        return token != lastToken
    }

    /// Processes everything new since the last run.
    ///
    /// Progress is saved after every batch, so a failure part-way through only
    /// retries the batches that did not complete. Returns without doing anything
    /// if a run is already in progress.
    ///
    /// - Parameter curator: Also collects news from each batch. News is a convenience: if
    ///   curating fails, the batch still counts as processed.
    public func run(
        extractor: ActionExtractor,
        curator: NewsCurator? = nil,
        filter: NotificationFilter = NotificationFilter(),
        archive: ConversationArchive? = nil,
        onEvent: @Sendable (PipelineEvent) async -> Void
    ) async throws {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        if startsFresh {
            let floor = clock().addingTimeInterval(-initialLookback)
            if state.cursor < floor { state.cursor = floor }
        }
        let notifications = try source.fetch(after: state.cursor.addingTimeInterval(-overlap))
        startsFresh = false
        let unseen = notifications.filter { !seen.contains($0.id) }
        let (fresh, duplicates) = separateDuplicates(unseen)
        markSeen(duplicates)
        if !duplicates.isEmpty {
            await onEvent(.activity(duplicates.map { ActivityRecord(notification: $0, outcome: .skipped(.duplicate)) }))
        }
        let allowed = fresh.filter { $0.hasContent && filter.allows($0) }
        // Keep everything allowed for context (replies, summaries, questions) before analysis.
        archive?.add(allowed)
        // The user's own messages are context only.
        let relevant = allowed.filter { !$0.isFromUser }
        let relevantIDs = Set(relevant.map(\.id))
        let skipped = fresh.filter { !relevantIDs.contains($0.id) }
        markSeen(skipped)
        if !skipped.isEmpty {
            await onEvent(.activity(skipped.map { note in
                ActivityRecord(notification: note, outcome: .skipped(filter.skipReason(for: note) ?? .empty))
            }))
        }

        for batch in relevant.chunked(into: batchSize) {
            // Verification codes are time-critical: surface them before the (possibly slow) model call.
            var codes: [ActionItem] = []
            var codeValues: Set<String> = []
            for note in batch {
                guard let item = VerificationCodeDetector.item(for: note), let code = item.verificationCode else { continue }
                codeValues.insert(code)
                if announcedCodeIDs.insert(note.id).inserted { codes.append(item) }
            }
            // Received files become items by rule as well.
            let files = AttachmentRule.items(in: batch)
            codes += files
            if !codes.isEmpty { await onEvent(.extracted(items: codes, analyzedCount: 0)) }

            await onEvent(.analyzing(count: batch.count))
            let messages = batch.filter { $0.attachmentPath == nil }
            let analyzer = MentionAnalyzer(userNames: extractor.userNames)
            var items = try await extractor.extract(from: messages).filter { item in
                !codeValues.contains { item.verificationCode == $0 || (item.kind == .code && item.summary.contains($0)) }
            }
            // Substantive group messages the model passed over become notices by rule.
            let covered = Set((codes + items).flatMap(\.sourceIDs))
            items += GroupNoticeRule.items(in: messages, analyzer: analyzer, covered: covered)
            // One-to-one chats are always shown.
            items = DirectMessageRule.apply(to: items, batch: messages, analyzer: analyzer,
                                            covered: covered.union(items.flatMap(\.sourceIDs)))
            items = Self.applyRules(filter, to: items, batch: messages)
            markSeen(batch)
            advanceCursor(to: batch.map(\.date).max())
            try persist()
            await onEvent(.extracted(items: items, analyzedCount: batch.count))

            var news: [NewsItem] = []
            if let curator, let curated = try? await curator.curate(messages), !curated.isEmpty {
                news = curated
                await onEvent(.news(news))
            }
            await onEvent(.activity(Self.activity(for: batch, items: codes + items, news: news, analyzer: analyzer)))
        }

        advanceCursor(to: notifications.map(\.date).max())
        try persist()
    }

    /// "紧急" rules raise priority; "仅关注" rules turn items into low-priority notices.
    static func applyRules(_ filter: NotificationFilter, to items: [ActionItem], batch: [AppNotification]) -> [ActionItem] {
        guard !filter.rules.isEmpty else { return items }
        let byID = Dictionary(batch.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.map { item in
            let actions = item.sourceIDs.compactMap { byID[$0] }.compactMap(filter.action(for:))
            var item = item
            if actions.contains(.urgent) {
                item.priority = .high
            } else if actions.contains(.notice), item.kind != .code {
                item.kind = .notice
                item.priority = .low
            }
            return item
        }
    }

    static func activity(for batch: [AppNotification], items: [ActionItem], news: [NewsItem],
                         analyzer: MentionAnalyzer) -> [ActivityRecord] {
        batch.map { note in
            if let item = items.first(where: { $0.sourceIDs.contains(note.id) }) {
                return ActivityRecord(notification: note, outcome: .item(kind: item.kind, summary: item.summary))
            }
            if let story = news.first(where: { $0.sourceIDs.contains(note.id) }) {
                return ActivityRecord(notification: note, outcome: .news(headline: story.headline))
            }
            let reason: ActivityRecord.SkipReason = analyzer.addressee(of: note) == .others ? .mentionsOthers : .notActionable
            return ActivityRecord(notification: note, outcome: .skipped(reason))
        }
    }

    /// Content key: app (case-insensitive) and the start of the body, ignoring whitespace.
    static func contentKey(_ note: AppNotification) -> String? {
        let body = note.body.filter { !$0.isWhitespace }
        guard body.count >= 4 else { return nil }  // Too short to tell repeats from duplicates.
        return note.appID.lowercased() + "|" + body.prefix(80)
    }

    private func separateDuplicates(_ notes: [AppNotification]) -> (fresh: [AppNotification], duplicates: [AppNotification]) {
        let now = Date()
        recentContents = recentContents.filter { now.timeIntervalSince($0.value) < 2 * duplicateWindow }
        var fresh: [AppNotification] = []
        var duplicates: [AppNotification] = []
        for note in notes {
            guard let key = Self.contentKey(note) else {
                fresh.append(note)
                continue
            }
            if let earlier = recentContents[key], abs(earlier.timeIntervalSince(note.date)) <= duplicateWindow {
                duplicates.append(note)
            } else {
                recentContents[key] = note.date
                fresh.append(note)
            }
        }
        return (fresh, duplicates)
    }

    private func markSeen(_ notifications: [AppNotification]) {
        for note in notifications where seen.insert(note.id).inserted {
            state.seenIDs.append(note.id)
        }
        if state.seenIDs.count > maxSeenIDs {
            state.seenIDs.removeFirst(state.seenIDs.count - maxSeenIDs)
            seen = Set(state.seenIDs)
        }
    }

    private func advanceCursor(to date: Date?) {
        if let date, date > state.cursor { state.cursor = date }
    }

    private func persist() throws {
        try stateStore?.save(state)
    }
}
