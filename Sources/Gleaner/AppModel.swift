import AppKit
import GleanerCore
import OSLog

/// Logs counts and errors only, never notification content.
private let log = Logger(subsystem: "app.gleaner.Gleaner", category: "pipeline")

/// App-wide state for the menu bar UI.
@MainActor
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case analyzing(count: Int)
        case accessDenied
        case failed(String)
    }

    /// Which page the panel shows.
    enum Route { case main, settings, history, ask }

    struct RuleSuggestion {
        let rule: UserRule
        let examples: [IrrelevantExample]
    }

    /// How to treat an item the user marks "不相关".
    enum IrrelevantScope {
        /// Mute the chat or sender the item came from.
        case conversation
        /// Ignore the app altogether.
        case app
        /// Just this item; remembered as a counter-example for the model.
        case once
    }

    @Published private(set) var items: [ActionItem] = []
    @Published private(set) var history: [ResolvedItem] = []
    /// News and trending topics for browsing, newest first. Not counted as items.
    @Published private(set) var news: [NewsItem] = []
    /// What happened to each notification in the last day, newest first.
    @Published private(set) var activity: [ActivityRecord] = []
    /// Today's remaining timed events.
    @Published private(set) var events: [CalendarEvent] = []
    /// The active Focus, e.g. "工作".
    @Published private(set) var focusMode: String?
    /// Conversation summaries by conversation, with loading and failure states.
    @Published private(set) var summaries: [ConversationKey: SummaryState] = [:]
    /// Conversations with the assistant, most recent first.
    @Published private(set) var chats: [ChatSession] = []
    /// The conversation on screen; nil for a new one not yet started.
    @Published var currentChatID: UUID?
    /// The turn whose answer is streaming in.
    @Published private(set) var answeringTurnID: UUID?
    /// A rule drawn from items the user marked irrelevant, waiting for the user's approval.
    @Published private(set) var ruleSuggestion: RuleSuggestion?

    enum SummaryState: Equatable {
        case loading
        /// Text so far; `done` once the model has finished.
        case text(String, done: Bool)
        case failed
    }

    private var answerTask: Task<Void, Never>?
    private var summaryTasks: [ConversationKey: Task<Void, Never>] = [:]
    @Published private(set) var status: Status = .idle {
        didSet { if status != oldValue { refreshModelSetup() } }
    }
    /// No usable model yet: a cloud model without a key, or a local one that isn't answering.
    @Published private(set) var needsModelSetup = false
    @Published private(set) var analyzedToday = 0
    /// A verification code that just arrived, shown in the menu bar for a minute.
    @Published private(set) var flashingCode: String?
    /// Advances periodically so time-based visibility (snoozes, expiry) refreshes the UI.
    @Published private(set) var now = Date()
    @Published var route: Route = .main
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            messagesSwitch.isOn = settings.readMessages
            weChatFilesSwitch.isOn = settings.readWeChatFiles
            mailSwitch.isOn = settings.readMail
            if settings.showCalendar != oldValue.showCalendar { refreshEvents() }
            if settings.briefings && !oldValue.briefings { BriefingNotifier.requestPermission() }
            if settings.provider != oldValue.provider { refreshModelSetup() }
        }
    }

    private let pipeline: NotificationPipeline
    /// Recent messages per conversation, for replies, summaries and questions.
    let archive: ConversationArchive
    private let itemStore: JSONFileStore<[ActionItem]>
    private let historyStore: JSONFileStore<[ResolvedItem]>
    private let newsStore: JSONFileStore<[NewsItem]>
    private let activityStore: JSONFileStore<[ActivityRecord]>
    private let chatStore: JSONFileStore<[ChatSession]>
    private let foregroundStore: JSONFileStore<ForegroundHistory>
    /// When each app was in front, to tell where the message record may have gaps.
    private var foreground: ForegroundHistory
    private var workspaceObservers: [NSObjectProtocol] = []
    private let secrets: SecretStore
    private let calendar = CalendarService()
    private let messagesSwitch: SourceSwitch
    private let weChatFilesSwitch: SourceSwitch
    private let mailSwitch: SourceSwitch
    private let defaults = UserDefaults.standard
    private var pollTimer: Timer?
    private var housekeepingTimer: Timer?
    private var flashTask: Task<Void, Never>?
    private var isRunning = false
    private var needsRerun = false
    private var lastFailure: Date?
    private var didOfferAuthorization = false

    /// How often the source is polled for changes.
    private let pollInterval: TimeInterval = 3
    /// How long to wait before retrying after an error.
    private let retryInterval: TimeInterval = 60
    /// How often expiry and snoozes are re-evaluated.
    private let housekeepingInterval: TimeInterval = 30
    /// How long a new code stays in the menu bar.
    private let codeFlashDuration: Duration = .seconds(60)
    /// History kept for restoring items.
    private let historyLimit = 200
    private let historyLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Counter-examples passed to the model.
    private let exampleLimit = 20

    init(secrets: SecretStore? = nil, dataDirectory: URL = AppModel.defaultDataDirectory) {
        // API keys live in a private file; keys saved in the keychain by earlier versions move over on first use.
        self.secrets = secrets ?? MigratingSecretStore(
            primary: FileSecretStore(url: dataDirectory.appendingPathComponent("secrets.json")),
            legacy: KeychainSecretStore())
        var settings = AppSettings.load()
        let messagesSwitch = SourceSwitch(settings.readMessages)
        let weChatFilesSwitch = SourceSwitch(settings.readWeChatFiles)
        self.messagesSwitch = messagesSwitch
        self.weChatFilesSwitch = weChatFilesSwitch
        let mailSwitch = SourceSwitch(settings.readMail)
        self.mailSwitch = mailSwitch
        // Notifications first, so a message seen twice keeps its notification's wording.
        let source = CompositeNotificationSource([
            // Mail's own notifications are redundant when its inboxes are read directly.
            ExcludingSource(source: MacNotificationCenterSource(), excludedApps: [MailSource.appID], when: mailSwitch),
            IPhoneNotificationSource(),
            ToggleableSource(source: MessagesSource(), toggle: messagesSwitch),
            ToggleableSource(source: WeChatFileSource(), toggle: weChatFilesSwitch),
            ToggleableSource(source: MailSource(), toggle: mailSwitch),
        ])
        LoginItem.configureOnFirstLaunch(settings: &settings)
        self.settings = settings
        self.itemStore = JSONFileStore(url: dataDirectory.appendingPathComponent("items.json"))
        self.historyStore = JSONFileStore(url: dataDirectory.appendingPathComponent("history.json"))
        self.newsStore = JSONFileStore(url: dataDirectory.appendingPathComponent("news.json"))
        self.activityStore = JSONFileStore(url: dataDirectory.appendingPathComponent("activity.json"))
        self.chatStore = JSONFileStore(url: dataDirectory.appendingPathComponent("chats.json"))
        self.foregroundStore = JSONFileStore(url: dataDirectory.appendingPathComponent("foreground.json"))
        self.foreground = foregroundStore.load() ?? ForegroundHistory()
        self.archive = ConversationArchive(store: JSONFileStore(url: dataDirectory.appendingPathComponent("archive.json")))
        self.pipeline = NotificationPipeline(
            source: source,
            stateStore: JSONFileStore(url: dataDirectory.appendingPathComponent("pipeline.json"))
        )
        self.items = itemStore.load() ?? []
        self.history = historyStore.load() ?? []
        self.news = (newsStore.load() ?? []).merging([])
        self.activity = (activityStore.load() ?? []).merging([])
        self.chats = (chatStore.load() ?? []).trimmedForStorage()
        self.analyzedToday = loadDailyCount()
        settings.save()
        calendar.observeChanges { [weak self] in self?.refreshEvents() }
        observeForegroundApps()
        refreshModelSetup()
        if settings.showCalendar && !(CalendarService.canReadEvents && CalendarService.canReadReminders) {
            // Settings from before reminders were supported only granted calendar access.
            Task { [weak self] in
                _ = await self?.calendar.requestAccess()
                self?.refreshEvents()
            }
        }
        if settings.briefings && LoginItem.isInstalled { BriefingNotifier.requestPermission() }
        if archive.isEmpty {
            // Start with whatever history the sources still hold.
            let (pipeline, archive, filter) = (pipeline, archive, settings.notificationFilter)
            Task.detached { await pipeline.backfill(archive, since: Date().addingTimeInterval(-7 * 86_400), filter: filter) }
        }
        housekeeping()

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: housekeepingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.housekeeping() }
        }
        Task { await poll() }
    }

    static var defaultDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gleaner", isDirectory: true)
    }

    // MARK: - Items

    /// Items currently shown: not snoozed, highest priority first.
    var visibleItems: [ActionItem] {
        items.filter { ItemLifecycle.isVisible($0, now: now) }.sortedForDisplay()
    }

    var snoozedCount: Int { items.count - visibleItems.count }

    /// Visible items that ask for action. "值得关注" notices are listed but not counted.
    var actionableItems: [ActionItem] { visibleItems.filter { $0.kind != .notice } }

    /// True during a Focus when the user wants the menu bar kept quiet.
    var isQuieted: Bool { focusMode != nil && settings.quietDuringFocus }

    /// What the menu bar counts: during a quiet Focus, only urgent items.
    var menuBarItems: [ActionItem] {
        isQuieted ? actionableItems.filter { $0.priority == .high } : actionableItems
    }

    /// The newest "值得关注" notice, shown in the menu bar when nothing needs action (not during a quiet Focus).
    var latestNotice: ActionItem? {
        guard !isQuieted else { return nil }
        return visibleItems.filter { $0.kind == .notice }.max { $0.notificationDate < $1.notificationDate }
    }

    /// Visible items as one group per conversation, filed under its most pressing kind.
    var sections: [(kind: ActionKind, groups: [[ActionItem]])] {
        visibleItems.conversationSections(order: ActionKind.displayOrder)
    }

    func complete(_ item: ActionItem) {
        resolve([item], as: .done)
    }

    func completeAll() {
        resolve(visibleItems, as: .done)
    }

    func updateReply(for id: ActionItem.ID, to text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].suggestedReply != text else { return }
        items[index].suggestedReply = text
        saveItems()
    }

    func snooze(_ item: ActionItem, until date: Date) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].snoozedUntil = date
        saveItems()
    }

    func markIrrelevant(_ item: ActionItem, scope: IrrelevantScope) {
        switch scope {
        case .conversation:
            let key = ConversationKey(appID: item.appID, title: item.sourceTitle)
            if !settings.mutedConversations.contains(key) { settings.mutedConversations.append(key) }
        case .app:
            if !settings.ignoredAppIDs.contains(item.appID) { settings.ignoredAppIDs.append(item.appID) }
        case .once:
            let example = IrrelevantExample(summary: item.summary, appID: item.appID, conversation: item.sourceTitle,
                                            excerpt: item.sourceExcerpt)
            settings.irrelevantExamples = Array((settings.irrelevantExamples + [example]).suffix(exampleLimit))
            suggestRule()
        }
        // Muting a conversation or an app also clears what is already listed from it.
        let filter = settings.notificationFilter
        let affected = scope == .once ? [item] : items.filter { $0.id == item.id || !filter.allows($0) }
        resolve(affected, as: .irrelevant)
    }

    func restore(_ resolved: ResolvedItem) {
        history.removeAll { $0.id == resolved.id }
        var item = resolved.item
        item.snoozedUntil = nil
        item.createdAt = Date()  // A fresh day before it is archived again.
        items.append(item)
        saveItems()
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    func clearActivity() {
        activity.removeAll()
        try? activityStore.save(activity)
    }

    func unmute(_ key: ConversationKey) {
        settings.mutedConversations.removeAll { $0 == key }
    }

    private func resolve(_ resolved: [ActionItem], as resolution: ResolvedItem.Resolution) {
        guard !resolved.isEmpty else { return }
        let ids = Set(resolved.map(\.id))
        items.removeAll { ids.contains($0.id) }
        history.insert(contentsOf: resolved.map { ResolvedItem(item: $0, resolution: resolution) }, at: 0)
        trimHistory()
        saveItems()
        saveHistory()
    }

    /// Archives expired items, refreshes snoozes and events, and sends a due briefing.
    private func housekeeping() {
        now = Date()
        refreshEvents()
        // During a Focus the briefing waits; it is still sent if the Focus ends within the hour.
        if settings.briefings && !isQuieted {
            BriefingNotifier.sendIfDue(actionable: actionableItems.count, news: news.count)
        }
        let expired = items.filter { ItemLifecycle.isExpired($0, now: now) }
        if !expired.isEmpty {
            log.info("Archiving \(expired.count) expired items")
            resolve(expired, as: .archived)
        }
        trimHistory()
    }

    private func trimHistory() {
        let cutoff = Date().addingTimeInterval(-historyLifetime)
        let trimmed = Array(history.filter { $0.date > cutoff }.prefix(historyLimit))
        if trimmed.count != history.count { history = trimmed }
    }

    // MARK: - Calendar

    /// The upcoming events shown in the panel.
    var upcomingEvents: [CalendarEvent] { events.upcoming(now: now) }

    /// An event about to start, for the menu bar.
    var imminentEvent: CalendarEvent? { events.first { $0.isImminent(now: now) } }

    /// Turns the calendar on, asking for calendar and reminders access first.
    func enableCalendar() async -> Bool {
        let granted = await calendar.requestAccess()
        if granted { settings.showCalendar = true }
        refreshEvents()
        return granted
    }

    // MARK: - Schedule suggestions

    /// Asks the model, in the background, which new items are worth a calendar event or reminder.
    private func suggestSchedules(for added: [ActionItem]) {
        guard settings.scheduleSuggestions else { return }
        let candidates = ScheduleSuggester.candidates(added)
        guard !candidates.isEmpty else { return }
        var configuration = settings.provider
        configuration.reasoning = false
        let suggester = ScheduleSuggester(provider: configuration.makeProvider(apiKey: apiKey(for: settings.provider)),
                                          appName: { AppDirectory.shared.name(for: $0) })
        Task { [weak self] in
            do {
                let suggestions = try await suggester.suggest(for: candidates)
                guard let self, !suggestions.isEmpty else { return }
                for index in items.indices {
                    if let suggestion = suggestions[items[index].id] { items[index].schedule = suggestion }
                }
                saveItems()
                log.info("Suggested \(suggestions.count) of \(candidates.count) items for the calendar")
            } catch {
                log.error("Schedule suggestion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Adds the (possibly edited) suggestion to Calendar or Reminders and files the item away.
    @discardableResult
    func addSchedule(for item: ActionItem, _ suggestion: ScheduleSuggestion) async -> Bool {
        let app = AppDirectory.shared.name(for: item.appID)
        let source = item.sourceTitle.isEmpty ? app : "\(app)「\(item.sourceTitle)」"
        let note = [source, item.sourceExcerpt].filter { !$0.isEmpty }.joined(separator: "\n")
        guard await calendar.add(suggestion, source: note) else { return false }
        resolve([item], as: .scheduled)
        refreshEvents()
        return true
    }

    func dismissSchedule(for item: ActionItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].schedule = nil
        saveItems()
    }

    // MARK: - Files

    private var locatedFiles: [String: String?] = [:]

    /// The item's files, plus WeChat files its messages mention that are still on disk.
    func files(for item: ActionItem) -> [String] {
        var result = item.files
        guard item.appID.lowercased() == WeChatFileSource.appID else { return result }
        for name in item.mentionedFiles where !result.contains(where: { ($0 as NSString).lastPathComponent == name }) {
            if locatedFiles[name] == nil { locatedFiles[name] = .some(WeChatFileSource().locate(fileNamed: name)?.path) }
            if let found = locatedFiles[name], let path = found { result.append(path) }
        }
        return result
    }

    private var fileOrigins: [String: (conversation: String, sender: String?)] = [:]

    /// The chat and sender a received file came from, from the message announcing it. Found
    /// origins are kept; misses are looked up again, as the message may arrive after the file.
    func origin(ofFile path: String) -> (conversation: String, sender: String?)? {
        if let known = fileOrigins[path] { return known }
        guard let found = archive.origin(ofFileNamed: (path as NSString).lastPathComponent) else { return nil }
        fileOrigins[path] = found
        return found
    }

    // MARK: - Opening items

    /// The WeChat chat to open for an item, when finding chats is on and possible. Logs why not
    /// for WeChat items.
    func weChatChat(for item: ActionItem) -> String? {
        guard WeChatLocator.handles(item.appID) else { return nil }
        let name = item.attachmentPath.flatMap { origin(ofFile: $0)?.conversation } ?? item.sourceTitle
        let reason: String? = !settings.locateWeChatChats ? "turned off"
            : !WeChatLocator.isInstalled ? "WeChat for Mac not installed"
            : !WeChatLocator.isTrusted ? "no Accessibility access"
            : name.isEmpty ? "item has no chat name" : nil
        if let reason {
            log.info("Not locating the WeChat chat: \(reason, privacy: .public)")
            return nil
        }
        return name
    }

    /// Opens where the item came from: the message itself for mail, the chat for WeChat,
    /// otherwise the app.
    func open(_ item: ActionItem) {
        if let chat = weChatChat(for: item) {
            Task { await WeChatLocator.open(conversation: chat) }
            return
        }
        guard item.appID.lowercased() == MailSource.appID,
              let rowID = item.sourceIDs.compactMap(MailSource.rowID(fromNotificationID:)).max() else {
            AppDirectory.shared.open(item.appID)
            return
        }
        Task.detached(priority: .userInitiated) {
            let source = MailSource()
            if let url = source.messageURL(forRowID: rowID) {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
                return
            }
            // Some senders leave out the Message-ID; ask Mail for the message by its number instead.
            if let location = source.location(forRowID: rowID), Self.openInMail(rowID: rowID, location: location) { return }
            await MainActor.run { AppDirectory.shared.open(MailSource.appID) }
        }
    }

    /// Opens a message through Mail's scripting. The first use asks the user to allow Gleaner to
    /// control Mail. Runs off the main thread.
    nonisolated private static func openInMail(rowID: Int64, location: (account: String, mailbox: [String])) -> Bool {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // Nested mailboxes: mailbox "子" of mailbox "父" of account.
        let mailbox = location.mailbox.reversed().map { "mailbox \(quoted($0))" }.joined(separator: " of ")
        let source = """
        tell application "Mail"
            set theAccount to first account whose id is \(quoted(location.account))
            set theMessage to first message of \(mailbox) of theAccount whose id is \(rowID)
            open theMessage
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log.error("Opening mail through scripting failed: \(error[NSAppleScript.errorNumber] as? Int ?? 0)") }
        return error == nil
    }

    enum ScheduleTarget { case reminder, event }

    /// When the item is due, if its due text can be read.
    func due(of item: ActionItem) -> DueDateParser.Due? {
        DueDateParser.parse(item.due, now: item.createdAt)
    }

    /// Hands the item to Reminders or Calendar and files it away; false when access was refused.
    @discardableResult
    func schedule(_ item: ActionItem, as target: ScheduleTarget) async -> Bool {
        let app = AppDirectory.shared.name(for: item.appID)
        let source = item.sourceTitle.isEmpty ? app : "\(app)「\(item.sourceTitle)」"
        let notes = [source, item.sourceExcerpt].filter { !$0.isEmpty }.joined(separator: "\n")
        let due = due(of: item)
        let saved: Bool
        switch target {
        case .reminder: saved = await calendar.addReminder(title: item.summary, notes: notes, due: due)
        case .event:
            guard let due else { return false }
            saved = await calendar.addEvent(title: item.summary, notes: notes, due: due)
        }
        if saved {
            resolve([item], as: .scheduled)
            refreshEvents()
        }
        return saved
    }

    func completeReminder(_ reminder: CalendarEvent) {
        events.removeAll { $0.id == reminder.id }
        calendar.completeReminder(id: reminder.id)
    }

    private func refreshEvents() {
        guard settings.showCalendar else {
            if !events.isEmpty { events = [] }
            return
        }
        Task {
            let latest = await calendar.today()
            if latest != events { events = latest }
        }
    }

    // MARK: - Verification codes

    private func announce(_ newItems: [ActionItem]) {
        guard let code = newItems.last(where: { ItemLifecycle.isFreshCode($0) })?.verificationCode else { return }
        if settings.autoCopyCodes { Clipboard.copy(code) }
        flashingCode = code
        flashTask?.cancel()
        let duration = codeFlashDuration
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.flashingCode = nil
        }
    }

    // MARK: - News

    func dismiss(_ item: NewsItem) {
        news.removeAll { $0.id == item.id }
        saveNews()
    }

    func clearNews() {
        news.removeAll()
        saveNews()
    }

    // MARK: - Authorization

    /// Opens System Settings with a drag-and-drop guide for Full Disk Access.
    func startAuthorizationGuide() {
        AuthorizationGuide.shared.start { [weak self] in self?.checkNow() }
    }

    // MARK: - API keys

    func apiKey(for configuration: ProviderConfiguration) -> String {
        secrets.secret(for: configuration.secretAccount)
    }

    func setAPIKey(_ key: String, for configuration: ProviderConfiguration) {
        secrets.setSecret(key.trimmingCharacters(in: .whitespacesAndNewlines), for: configuration.secretAccount)
        refreshModelSetup()
    }

    private func refreshModelSetup() {
        let provider = settings.provider
        let needed: Bool
        if provider.isLocal {
            if case .failed = status { needed = true } else { needed = false }
        } else {
            needed = apiKey(for: provider).isEmpty
        }
        if needed != needsModelSetup { needsModelSetup = needed }
    }

    /// The key of a search channel, kept apart from model keys.
    func searchKey(for channel: WebSearchChannel) -> String {
        secrets.secret(for: channel.secretAccount)
    }

    func setSearchKey(_ key: String, for channel: WebSearchChannel) {
        secrets.setSecret(key.trimmingCharacters(in: .whitespacesAndNewlines), for: channel.secretAccount)
    }

    /// Runs one search through `channel` and describes the result.
    func testSearch(channel: WebSearchChannel, channelKey: String, provider: ProviderConfiguration, modelKey: String) async -> String {
        let key = provider.searchKey(for: channel, channelKey: channelKey, modelKey: modelKey)
        guard !key.isEmpty else { return "需填写 Key" }
        do {
            let results = try await channel.makeService(apiKey: key).search("今日新闻", question: "今天有什么新闻")
            return results.isEmpty ? "已连接，没有结果" : "可用，\(results.count) 条结果"
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Processing

    func checkNow() {
        lastFailure = nil
        Task { await process() }
    }

    private func poll() async {
        let focus = FocusStatus.activeMode()
        if focus != focusMode { focusMode = focus }
        if await pipeline.hasChanges() {
            await process()
            return
        }
        switch status {
        case .failed, .accessDenied:
            if let lastFailure, Date().timeIntervalSince(lastFailure) >= retryInterval { await process() }
        default:
            break
        }
    }

    private func process() async {
        guard !isRunning else {
            needsRerun = true
            return
        }
        isRunning = true
        defer { isRunning = false }

        repeat {
            needsRerun = false
            await runPipelineOnce()
        } while needsRerun
    }

    private func runPipelineOnce() async {
        let extractor = makeExtractor(settings: settings, apiKey: apiKey(for: settings.provider))
        do {
            let curator = settings.collectNews ? makeCurator(settings: settings) : nil
            try await pipeline.run(extractor: extractor, curator: curator, filter: settings.notificationFilter,
                                   archive: archive) { event in
                await self.handle(event)
            }
            status = .idle
            lastFailure = nil
        } catch NotificationSourceError.accessDenied {
            log.error("Notification database is not readable; Full Disk Access is required")
            status = .accessDenied
            lastFailure = Date()
            // The installed app offers the guide once per launch; development builds rely on the terminal's access.
            if LoginItem.isInstalled, !didOfferAuthorization, !AuthorizationGuide.shared.isShowing {
                didOfferAuthorization = true
                startAuthorizationGuide()
            }
        } catch {
            log.error("Pipeline run failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            lastFailure = Date()
        }
    }

    private func handle(_ event: PipelineEvent) {
        switch event {
        case .analyzing(let count):
            log.info("Analyzing \(count) notifications with \(self.settings.provider.model, privacy: .public)")
            status = .analyzing(count: count)
        case .extracted(let newItems, let analyzedCount):
            if analyzedCount > 0 {
                log.info("Analyzed \(analyzedCount) notifications, found \(newItems.count) action items")
            }
            // Rules may have changed while the batch was being analyzed.
            let kept = newItems.filter { settings.notificationFilter.allows($0) }
            let before = Set(items.map(\.id))
            items = items.merging(kept)
            let added = items.filter { !before.contains($0.id) }
            saveItems()
            addToDailyCount(analyzedCount)
            announce(added)
            suggestSchedules(for: added)
            housekeeping()
        case .news(let newNews):
            log.info("Collected \(newNews.count) news items")
            news = news.merging(newNews)
            saveNews()
        case .activity(let records):
            activity = activity.merging(records)
            try? activityStore.save(activity)
        }
    }

    private func makeExtractor(settings: AppSettings, apiKey: String) -> ActionExtractor {
        var replyConfiguration = settings.provider
        replyConfiguration.reasoning = false
        let archive = archive
        let replies = settings.suggestReplies
            ? ReplyWriter(provider: replyConfiguration.makeProvider(apiKey: apiKey), context: { item in
                archive.messages(in: ConversationKey(appID: item.appID, title: item.sourceTitle), limit: 30)
            })
            : nil
        var extractor = Self.makeExtractor(configuration: settings.provider, apiKey: apiKey, userNames: settings.userNameList,
                                           irrelevantExamples: settings.irrelevantExamples.map(\.promptLine), replyWriter: replies)
        extractor.history = { archive.messages(in: $0, limit: 40) }
        return extractor
    }

    private static func makeExtractor(configuration: ProviderConfiguration, apiKey: String, userNames: [String],
                                      irrelevantExamples: [String] = [], replyWriter: ReplyWriter? = nil) -> ActionExtractor {
        ActionExtractor(
            provider: configuration.makeProvider(apiKey: apiKey),
            userNames: userNames,
            irrelevantExamples: irrelevantExamples,
            replyWriter: replyWriter,
            appName: { AppDirectory.shared.name(for: $0) }
        )
    }

    // MARK: - Summaries, questions, rules

    private var assistant: Assistant {
        var configuration = settings.provider
        configuration.reasoning = false
        return Assistant(provider: configuration.makeProvider(apiKey: apiKey(for: settings.provider)),
                         userNames: settings.userNameList)
    }

    /// Whether a conversation has enough history to summarize.
    func canSummarize(_ key: ConversationKey) -> Bool {
        archive.messages(in: key, limit: 3).count >= 3
    }

    func summarize(_ key: ConversationKey) {
        summaryTasks[key]?.cancel()
        summaries[key] = .loading
        let messages = archive.messages(in: key, limit: 80)
        let gaps = gapNotes(for: [key.appID], from: messages.first?.date ?? Date().addingTimeInterval(-86_400))
        let stream = assistant.summarize(messages, conversation: key.title, gaps: gaps)
        summaryTasks[key] = Task { [weak self] in
            await Self.consume(stream) { self?.summaries[key] = $0 }
        }
    }

    func dismissSummary(_ key: ConversationKey) {
        summaryTasks[key]?.cancel()
        summaries[key] = nil
    }

    // MARK: - Foreground apps

    private func observeForegroundApps() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                     queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.recordForeground(app?.bundleIdentifier) }
        })
        // Asleep, nothing is in front; awake, whatever is frontmost is.
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordForeground(nil) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordForeground(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
        })
        recordForeground(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func recordForeground(_ appID: String?) {
        let before = foreground
        foreground.activate(appID)
        if foreground != before { try? foregroundStore.save(foreground) }
    }

    /// Lines naming when these apps were in front since `from`, for the model.
    private func gapNotes(for appIDs: Set<String>, from: Date) -> [String] {
        appIDs.sorted().compactMap { id in
            ForegroundHistory.describe(foreground.gaps(for: id, from: from), appName: AppDirectory.shared.name(for: id))
        }
    }

    // MARK: - Conversations

    var currentChat: ChatSession? { chats.first { $0.id == currentChatID } }

    /// What the next new conversation will be about, until its first question.
    @Published private(set) var pendingAttachments: [ChatAttachment] = []

    /// Files and messages waiting to be sent with the next question.
    var currentAttachments: [ChatAttachment] { pendingAttachments }

    /// Adds files to the next question, by reference: they are read where they are.
    func attach(files urls: [URL]) {
        // Only files whose text can be read.
        for url in urls where url.isFileURL && FileTextExtractor.canExtract(url) {
            let attachment = ChatAttachment.file(path: url.path)
            guard !pendingAttachments.contains(attachment) else { continue }
            pendingAttachments.append(attachment)
            // Read ahead, so the input can tell when only part of the file will be sent.
            Task { _ = try? await fileText(at: url.path) }
        }
    }

    /// How a waiting file will be sent: files share the budget of the configured model, and a
    /// file larger than its share is paged or cut. Nil until the file has been read.
    func delivery(ofPending path: String) -> FileDelivery? {
        let paths = pendingAttachments.compactMap { $0.kind == .file ? $0.path : nil }
        guard let index = paths.firstIndex(of: path), let content = fileTextsRead[path] else { return nil }
        let lengths = paths.map { fileTextsRead[$0]?.text.count ?? 0 }
        let share = ContextBudget.allocate(lengths, total: settings.provider.contextBudget.attachments)[index]
        if content.text.count <= share && !content.truncated { return .whole }
        guard canPageFiles else { return .truncated(characters: min(share, content.text.count)) }
        return .paged(sections: sections(of: path)?.count ?? 0)
    }

    /// Whether the configured model can read further sections of long files (it calls tools).
    private var canPageFiles: Bool { settings.provider.apiProtocol == .openAICompatible }

    /// Long files' sections, by path, made once.
    private var sectionCache: [String: DocumentSections] = [:]

    private func sections(of path: String) -> DocumentSections? {
        if let cached = sectionCache[path] { return cached }
        guard let content = fileTextsRead[path] else { return nil }
        let document = DocumentSections(text: content.text)
        sectionCache[path] = document
        return document
    }

    /// Long files of the current conversation the model may read further, by name; newer files
    /// win when two share a name.
    private func pageableFiles(in turns: [ChatTurn], plus paged: [String: Int]) -> [String: DocumentSections] {
        var files: [String: DocumentSections] = [:]
        let paths = turns.flatMap { Array($0.pagedFiles.keys) } + Array(paged.keys)
        for path in paths {
            if let document = sections(of: path) { files[(path as NSString).lastPathComponent] = document }
        }
        return files
    }

    /// Saves a pasted image (it has no file of its own) and adds it to the next question.
    func attach(image data: Data) {
        let folder = Self.defaultDataDirectory.appendingPathComponent("pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = folder.appendingPathComponent("截图 \(formatter.string(from: Date())).png")
        guard (try? data.write(to: file)) != nil else { return }
        attach(files: [file])
    }

    /// Opens the question page on a fresh conversation.
    func startNewChat() {
        currentChatID = nil
        pendingAttachments = []
        route = .ask
    }

    /// Opens the question page on a fresh conversation about a file or a message.
    /// A new conversation about files chosen elsewhere, e.g. from Finder's right-click menu.
    func startChat(aboutFiles urls: [URL]) {
        currentChatID = nil
        pendingAttachments = []
        attach(files: urls)
        route = .ask
    }

    func startChat(about attachment: ChatAttachment) {
        currentChatID = nil
        pendingAttachments = [attachment]
        route = .ask
    }

    /// The item as something to ask about: its file if readable, or the message and its chat.
    func attachment(for item: ActionItem) -> ChatAttachment {
        if let path = item.attachmentPath, FileTextExtractor.canExtract(URL(fileURLWithPath: path)) { return .file(path: path) }
        return .message(title: item.summary, appID: item.appID, conversation: item.sourceTitle,
                        excerpt: item.sourceExcerpt.isEmpty ? item.summary : item.sourceExcerpt)
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.removeAll { $0 == attachment }
    }

    /// Reads attachments into text: a file's contents, or a message with its recent chat. Files
    /// share `budget` characters; how each was sent is returned by path.
    private func read(_ attachments: [ChatAttachment], budget: Int,
                      canPage: Bool) async -> ([Assistant.Attachment], [String: FileDelivery]) {
        var contents: [String: FileTextExtractor.Content] = [:]
        for path in attachments.compactMap({ $0.kind == .file ? $0.path : nil }) {
            contents[path] = try? await fileText(at: path)
        }
        let paths = Array(contents.keys)
        let shares = Dictionary(uniqueKeysWithValues: zip(paths, ContextBudget.allocate(paths.map { contents[$0]!.text.count },
                                                                                      total: budget)))
        var result: [Assistant.Attachment] = []
        var deliveries: [String: FileDelivery] = [:]
        for attachment in attachments {
            switch attachment.kind {
            case .file:
                guard let path = attachment.path else { continue }
                do {
                    let content = try await fileText(at: path)
                    let (sent, delivery) = Assistant.fileAttachment(title: attachment.title, text: content.text,
                                                                    extractionCut: content.truncated,
                                                                    share: shares[path] ?? 0, canPage: canPage)
                    result.append(sent)
                    deliveries[path] = delivery
                } catch {
                    result.append(.init(title: attachment.title, text: "（\(error.localizedDescription)）"))
                }
            case .message:
                let appID = attachment.appID ?? ""
                let app = AppDirectory.shared.name(for: appID)
                let chat = archive.messages(in: ConversationKey(appID: appID, title: attachment.conversation ?? ""), limit: 40)
                var text = "来自\(app)「\(attachment.conversation ?? "")」的消息：\(attachment.excerpt ?? attachment.title)"
                if !chat.isEmpty { text += "\n\n这个会话最近的聊天记录（旧→新）：\n" + ConversationArchive.transcript(chat) }
                result.append(.init(title: attachment.title, text: text))
            }
        }
        return (result, deliveries)
    }

    /// Text of files, read once and kept for follow-up questions.
    @Published private var fileTextsRead: [String: FileTextExtractor.Content] = [:]
    private var fileTextTasks: [String: Task<FileTextExtractor.Content, Error>] = [:]

    /// Reads off the main thread; a file asked for again while being read is read once.
    private func fileText(at path: String) async throws -> FileTextExtractor.Content {
        if let cached = fileTextsRead[path] { return cached }
        let task = fileTextTasks[path] ?? Task.detached(priority: .userInitiated) {
            try FileTextExtractor.extract(from: URL(fileURLWithPath: path))
        }
        fileTextTasks[path] = task
        defer { fileTextTasks[path] = nil }
        let content = try await task.value
        fileTextsRead[path] = content
        return content
    }

    // MARK: - File summaries

    /// Key points of received files, by path.
    @Published private(set) var fileSummaries: [String: SummaryState] = [:]
    private var fileSummaryTasks: [String: Task<Void, Never>] = [:]

    func summarizeFile(_ path: String) {
        fileSummaryTasks[path]?.cancel()
        fileSummaries[path] = .loading
        let assistant = assistant
        fileSummaryTasks[path] = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await fileText(at: path)
                let stream = assistant.summarizeFile(named: (path as NSString).lastPathComponent, content: content,
                                                     partSize: min(20_000, settings.provider.contextBudget.attachments))
                await Self.consume(stream) { self.fileSummaries[path] = $0 }
            } catch {
                fileSummaries[path] = .text(error.localizedDescription, done: true)
            }
        }
    }

    func dismissFileSummary(_ path: String) {
        fileSummaryTasks[path]?.cancel()
        fileSummaries[path] = nil
    }

    func openChat(_ id: UUID) {
        currentChatID = id
        pendingAttachments = []
    }

    func deleteChat(_ id: UUID) {
        if currentChatID == id { currentChatID = nil }
        chats.removeAll { $0.id == id }
        saveChats()
    }

    /// Asks in the current conversation, starting one if needed, with the attachments waiting in
    /// the input. The answer streams into the turn.
    ///
    /// A conversation's context (instructions, open items, recent messages) is built at its first
    /// question and reused; everything new for a later question goes into that question's preamble,
    /// which is stored. Requests therefore repeat earlier ones exactly and only grow at the end,
    /// so the provider can serve the repeated part from its prompt cache.
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        answerTask?.cancel()
        finishAnswering()

        var configuration = settings.provider
        configuration.reasoning = false
        let key = apiKey(for: configuration)
        // The model's own search when it has one; otherwise the configured channel.
        let native = settings.webSearch && configuration.hasNativeWebSearch
        let search = settings.webSearch && !native
            ? configuration.makeWebSearch(channel: settings.searchChannel, channelKey: searchKey(for: settings.searchChannel),
                                          modelKey: key)
            : nil
        let assistant = Assistant(provider: configuration.makeProvider(apiKey: key, webSearch: native),
                                  userNames: settings.userNameList)
        let budget = configuration.contextBudget
        let canPage = canPageFiles

        let attachments = pendingAttachments
        pendingAttachments = []
        let turn = ChatTurn(question: question, attachments: attachments)
        let since = Date().addingTimeInterval(-86_400)
        let previous = currentChat
        let history = previous?.turns ?? []
        // Messages that arrived after the context (or the last question) was put together.
        var newMessages: [ArchivedMessage] = []
        if let previous {
            let cutoff = history.last?.date ?? previous.createdAt
            newMessages = archive.recent(since: cutoff, limit: 200)
        }
        // Older messages matching the question (and the previous one, for follow-ups like "那他呢").
        let earlier = archive.search([history.last?.question, question].compactMap { $0 }.joined(separator: " "),
                                     before: since, limit: 60)

        let context: String
        if let index = chats.firstIndex(where: { $0.id == currentChatID }) {
            if let saved = chats[index].context {
                context = saved
            } else {
                context = makeContext(assistant, since: since, canSearch: search != nil || native)
                chats[index].context = context
            }
            chats[index].turns.append(turn)
            chats[index].updatedAt = Date()
            chats.insert(chats.remove(at: index), at: 0)
        } else {
            context = makeContext(assistant, since: since, canSearch: search != nil || native)
            var session = ChatSession(turns: [turn])
            session.context = context
            chats.insert(session, at: 0)
            currentChatID = session.id
        }
        answeringTurnID = turn.id

        let turnID = turn.id
        let appName: @Sendable (String) -> String = { AppDirectory.shared.name(for: $0) }
        answerTask = Task { [weak self] in
            var text = ""
            do {
                let (read, deliveries) = await self?.read(attachments, budget: budget.attachments, canPage: canPage) ?? ([], [:])
                let preamble = Assistant.preamble(attachments: read, newMessages: newMessages, earlier: earlier, appName: appName)
                var partial: [String: Int] = [:]
                var paged: [String: Int] = [:]
                for (path, delivery) in deliveries {
                    switch delivery {
                    case .whole: break
                    case .paged(let sections): paged[path] = sections
                    case .truncated(let characters): partial[path] = characters
                    }
                }
                self?.updateTurn(turnID) {
                    $0.preamble = preamble
                    $0.partialFiles = partial
                    $0.pagedFiles = paged
                }
                var sent = turn
                sent.preamble = preamble
                let files = canPage ? self?.pageableFiles(in: history, plus: paged) ?? [:] : [:]
                let stream = assistant.converse(sent, history: history, context: context, search: search, nativeSearch: native,
                                                budget: budget, files: files)
                for try await event in stream {
                    switch event {
                    case .searching(let query):
                        self?.updateTurn(turnID) { $0.searches.append(query) }
                    case .text(let piece):
                        text += piece
                        let cleaned = Assistant.clean(text)
                        self?.updateTurn(turnID) { $0.answer = cleaned }
                    case .reading(let label):
                        self?.updateTurn(turnID) { $0.reads.append(label) }
                    case .usage(let usage):
                        log.info("Question used \(usage.promptTokens) prompt tokens, \(usage.cachedTokens) from cache")
                    }
                }
            } catch is CancellationError {
            } catch {
                log.error("Answer failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.updateTurn(turnID) { $0.failed = $0.answer.isEmpty }
            if self?.answeringTurnID == turnID { self?.finishAnswering() }
        }
    }

    /// A new conversation's context: instructions, open items and the last day of messages.
    private func makeContext(_ assistant: Assistant, since: Date, canSearch: Bool) -> String {
        let messages = archive.recent(since: since, limit: 500)
        return assistant.conversationContext(messages: messages, openItems: visibleItems, news: news, canSearch: canSearch,
                                             gaps: gapNotes(for: Set(messages.map(\.appID)), from: since),
                                             appName: { AppDirectory.shared.name(for: $0) })
    }

    private func updateTurn(_ id: UUID, _ change: (inout ChatTurn) -> Void) {
        for index in chats.indices {
            if let turn = chats[index].turns.firstIndex(where: { $0.id == id }) {
                change(&chats[index].turns[turn])
                return
            }
        }
    }

    private func finishAnswering() {
        answeringTurnID = nil
        saveChats()
    }

    private func saveChats() {
        try? chatStore.save(chats.trimmedForStorage())
    }

    /// Feeds a streamed answer into `update` as it grows.
    private static func consume(_ stream: AsyncThrowingStream<String, Error>, update: (SummaryState) -> Void) async {
        var text = ""
        do {
            for try await piece in stream {
                text += piece
                let cleaned = Assistant.clean(text)
                if !cleaned.isEmpty { update(.text(cleaned, done: false)) }
            }
            update(.text(Assistant.clean(text), done: true))
        } catch is CancellationError {
            return
        } catch {
            update(text.isEmpty ? .failed : .text(Assistant.clean(text), done: true))
        }
    }

    /// Apps that sent notifications recently, most active first.
    var recentApps: [String] {
        var counts: [String: Int] = [:]
        for record in activity { counts[record.appID, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: - Rule suggestions

    /// Once several items from one app were marked irrelevant, asks the model for a rule covering them.
    private func suggestRule() {
        guard ruleSuggestion == nil, let candidates = settings.irrelevantExamples.ruleCandidates() else { return }
        let suggester = RuleSuggester(provider: settings.provider.makeProvider(apiKey: apiKey(for: settings.provider)),
                                      appName: { AppDirectory.shared.name(for: $0) })
        Task { [weak self] in
            let rule = try? await suggester.suggest(from: candidates)
            guard let self else { return }
            if let rule {
                ruleSuggestion = RuleSuggestion(rule: rule, examples: candidates)
            } else {
                markSuggested(candidates)
            }
        }
    }

    func acceptRuleSuggestion() {
        guard let suggestion = ruleSuggestion else { return }
        ruleSuggestion = nil
        let rule = suggestion.rule
        let appName: (String) -> String = { AppDirectory.shared.name(for: $0) }
        settings.rules.append(rule)
        // The rule now handles these in code, which frees room for other examples.
        settings.irrelevantExamples.removeAll { rule.matches($0.notification, appName: appName($0.appID)) }
        let covered = items.filter { item in
            let note = AppNotification(id: item.id.uuidString, appID: item.appID, title: item.sourceTitle,
                                       body: item.sourceExcerpt.isEmpty ? item.summary : item.sourceExcerpt,
                                       date: item.notificationDate)
            return rule.matches(note, appName: appName(item.appID))
        }
        resolve(covered, as: .irrelevant)
    }

    func dismissRuleSuggestion() {
        guard let suggestion = ruleSuggestion else { return }
        ruleSuggestion = nil
        markSuggested(suggestion.examples)
    }

    private func markSuggested(_ examples: [IrrelevantExample]) {
        let offered = Set(examples)
        settings.irrelevantExamples = settings.irrelevantExamples.map {
            guard offered.contains($0) else { return $0 }
            var example = $0
            example.suggested = true
            return example
        }
    }

    /// Compiles and adds a rule; returns false when the model could not understand it.
    func addRule(_ text: String) async -> UserRule? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let compiler = RuleCompiler(provider: settings.provider.makeProvider(apiKey: apiKey(for: settings.provider)))
        return try? await compiler.compile(text)
    }

    /// Headlines need no reasoning, so the curator always runs with it off.
    private func makeCurator(settings: AppSettings) -> NewsCurator {
        var configuration = settings.provider
        configuration.reasoning = false
        return NewsCurator(
            provider: configuration.makeProvider(apiKey: apiKey(for: settings.provider)),
            appName: { AppDirectory.shared.name(for: $0) }
        )
    }

    /// Sends a few sample notifications through `configuration` and describes the result.
    func testConnection(configuration: ProviderConfiguration, apiKey: String, userNames: [String]) async -> String {
        let now = Date()
        let samples = [
            AppNotification(id: "sample-1", appID: "com.tencent.weworkmac", title: "打卡",
                            body: "11月3日打卡异常，请尽快处理", date: now),
            AppNotification(id: "sample-2", appID: "com.tencent.xinwechat", title: "项目群",
                            body: "张三: 好的收到", date: now),
            AppNotification(id: "sample-4", appID: "com.tencent.xinwechat", title: "王总",
                            body: "报价单今天下班前发我一下", date: now),
            AppNotification(id: "sample-3", appID: "com.apple.MobileSMS", title: "106900",
                            body: "【某某云】您的验证码为 482913，5分钟内有效。", date: now),
        ]
        let extractor = Self.makeExtractor(configuration: configuration, apiKey: apiKey, userNames: userNames)
        let start = Date()
        do {
            _ = try await extractor.extract(from: samples)
            let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
            return "连接正常，用时 \(seconds) 秒"
        } catch {
            return "连接失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    private func saveItems() {
        try? itemStore.save(items)
    }

    private func saveHistory() {
        try? historyStore.save(history)
    }

    private func saveNews() {
        try? newsStore.save(news)
    }

    private static var todayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func loadDailyCount() -> Int {
        defaults.string(forKey: "analyzedDay") == Self.todayKey ? defaults.integer(forKey: "analyzedCount") : 0
    }

    private func addToDailyCount(_ count: Int) {
        guard count > 0 else { return }
        if defaults.string(forKey: "analyzedDay") != Self.todayKey {
            defaults.set(Self.todayKey, forKey: "analyzedDay")
            analyzedToday = 0
        }
        analyzedToday += count
        defaults.set(analyzedToday, forKey: "analyzedCount")
    }
}
