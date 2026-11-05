import Foundation
import GleanerCore

/// User preferences, persisted in `UserDefaults` as JSON.
struct AppSettings: Codable, Equatable {
    var provider: ProviderConfiguration = ProviderPreset.default.configuration
    /// How the user is addressed in chats, separated by commas. Helps the model spot @mentions.
    var userNames: String = ""
    /// Bundle identifiers whose notifications are never analyzed, separated by commas.
    var ignoredApps: String = ""
    var showTopItemInMenuBar: Bool = true
    /// Also collect news and trending topics for browsing.
    var collectNews: Bool = true
    /// Copy a verification code to the clipboard as soon as it arrives.
    var autoCopyCodes: Bool = true
    /// Chats and senders the user muted ("不相关 → 忽略这个会话").
    var mutedConversations: [ConversationKey] = []
    /// Items the user marked "不相关" once: counter-examples for the model, and material for rule suggestions.
    var irrelevantExamples: [IrrelevantExample] = []
    /// Whether launch at login has been set up once, so the user's later choice is respected.
    var launchAtLoginConfigured: Bool = false
    /// The user's launch-at-login choice, kept so it can be re-registered after the app moves.
    var launchAtLogin: Bool = true
    /// Show today's events (needs calendar access).
    var showCalendar: Bool = false
    /// Morning and evening summary notifications.
    var briefings: Bool = true
    /// Read received texts from the Messages database.
    var readMessages: Bool = true
    /// Read new mail in Apple Mail's inboxes directly.
    var readMail: Bool = true
    /// Turn files received in WeChat into items.
    var readWeChatFiles: Bool = true
    /// During a Focus, the menu bar only shows codes, imminent events and urgent items.
    var quietDuringFocus: Bool = true
    /// Draft a reply for messages from people.
    var suggestReplies: Bool = true
    /// Let the assistant search the web when the provider offers it.
    var webSearch: Bool = true
    /// Where to search when the model can't by itself.
    var searchChannel: WebSearchChannel = .deepseek
    /// Rules written in plain words, compiled by the model.
    var rules: [UserRule] = []

    var userNameList: [String] { Self.split(userNames) }
    var ignoredAppSet: Set<String> { Set(Self.split(ignoredApps)) }

    /// Ignored apps in the order they were added.
    var ignoredAppIDs: [String] {
        get {
            var seen = Set<String>()
            return Self.split(ignoredApps).filter { seen.insert($0).inserted }
        }
        set { ignoredApps = newValue.joined(separator: ", ") }
    }

    var notificationFilter: NotificationFilter {
        // Gleaner's own notifications (briefings) are never analyzed.
        NotificationFilter(ignoredApps: ignoredAppSet.union([Bundle.main.bundleIdentifier ?? "app.gleaner.Gleaner"]),
                           mutedConversations: Set(mutedConversations),
                           rules: rules,
                           appName: { AppDirectory.shared.name(for: $0) })
    }

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static let defaultsKey = "settings"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case provider, userNames, ignoredApps, showTopItemInMenuBar, collectNews, autoCopyCodes,
             mutedConversations, irrelevantExamples, launchAtLoginConfigured, showCalendar, briefings,
             readMessages, readWeChatFiles, quietDuringFocus, suggestReplies, rules, launchAtLogin, webSearch, searchChannel, readMail
    }

    /// Settings saved by older versions lack newer keys; keep what is there, default the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        provider = try c.decodeIfPresent(ProviderConfiguration.self, forKey: .provider) ?? defaults.provider
        userNames = try c.decodeIfPresent(String.self, forKey: .userNames) ?? defaults.userNames
        ignoredApps = try c.decodeIfPresent(String.self, forKey: .ignoredApps) ?? defaults.ignoredApps
        showTopItemInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showTopItemInMenuBar) ?? defaults.showTopItemInMenuBar
        collectNews = try c.decodeIfPresent(Bool.self, forKey: .collectNews) ?? defaults.collectNews
        autoCopyCodes = try c.decodeIfPresent(Bool.self, forKey: .autoCopyCodes) ?? defaults.autoCopyCodes
        mutedConversations = try c.decodeIfPresent([ConversationKey].self, forKey: .mutedConversations) ?? []
        irrelevantExamples = IrrelevantExample.decodeList(from: c, forKey: .irrelevantExamples)
        launchAtLoginConfigured = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginConfigured) ?? false
        showCalendar = try c.decodeIfPresent(Bool.self, forKey: .showCalendar) ?? defaults.showCalendar
        briefings = try c.decodeIfPresent(Bool.self, forKey: .briefings) ?? defaults.briefings
        readMessages = try c.decodeIfPresent(Bool.self, forKey: .readMessages) ?? defaults.readMessages
        readWeChatFiles = try c.decodeIfPresent(Bool.self, forKey: .readWeChatFiles) ?? defaults.readWeChatFiles
        quietDuringFocus = try c.decodeIfPresent(Bool.self, forKey: .quietDuringFocus) ?? defaults.quietDuringFocus
        suggestReplies = try c.decodeIfPresent(Bool.self, forKey: .suggestReplies) ?? defaults.suggestReplies
        rules = try c.decodeIfPresent([UserRule].self, forKey: .rules) ?? []
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? defaults.webSearch
        searchChannel = (try? c.decodeIfPresent(WebSearchChannel.self, forKey: .searchChannel)) ?? defaults.searchChannel
        readMail = try c.decodeIfPresent(Bool.self, forKey: .readMail) ?? defaults.readMail
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
