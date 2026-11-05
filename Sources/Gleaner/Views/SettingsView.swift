import GleanerCore
import SwiftUI

/// Settings, shown in place of the item list. Edits apply only when saved.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updater = Updater.shared
    @State private var launchAtLogin = LoginItem.state

    @State private var draft = AppSettings()
    @State private var apiKey = ""
    @State private var searchKeys: [WebSearchChannel: String] = [:]
    @State private var editingSearchKey: Set<WebSearchChannel> = []
    @State private var testingSearch = false
    @State private var searchTestResult: String?
    /// Shows the key field; otherwise a saved key is shown masked.
    @State private var editingKey = false
    @State private var newRule = ""
    @State private var addingRule = false
    @State private var ruleFailed = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                generalSection
                sourcesSection
                shortcutsSection
                recognitionSection
                ignoredSection
                modelSection
                searchSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 520)
        }
        .background(Theme.canvas)
        .onAppear {
            load()
            launchAtLogin = LoginItem.state
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text("设置").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            HStack {
                Button {
                    model.route = .main
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("返回")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("保存", action: save)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section("通用") {
            Toggle(isOn: Binding(
                get: { launchAtLogin != .disabled },
                set: { enabled in
                    LoginItem.setEnabled(enabled)
                    draft.launchAtLogin = enabled
                    launchAtLogin = LoginItem.state
                }
            )) {
                Text("开机自动启动")
                if !LoginItem.isInstalled {
                    Text("安装后可用")
                } else if launchAtLogin == .requiresApproval {
                    Text("需在登录项中允许")
                }
            }
            .disabled(!LoginItem.isInstalled)
            if launchAtLogin == .requiresApproval {
                Button("打开登录项") { LoginItem.openSystemSettings() }
                    .buttonStyle(PillButtonStyle())
            }
            Toggle("菜单栏显示首条待办", isOn: $draft.showTopItemInMenuBar)
            if updater.isAvailable {
                Toggle(isOn: $updater.automaticallyChecks) {
                    Text("自动检查更新")
                    Text("当前版本 \(Updater.version)")
                }
                Button("检查更新") { updater.checkForUpdates() }
                    .buttonStyle(PillButtonStyle())
            }
            Toggle(isOn: $draft.briefings) {
                Text("早晚简报")
                Text(Briefing.hours.map { "\($0):00" }.joined(separator: " 和 "))
            }
            Toggle("专注模式下只提示紧急事项", isOn: $draft.quietDuringFocus)
        }
    }

    private var sourcesSection: some View {
        Section("读取") {
            Toggle("短信与 iMessage", isOn: $draft.readMessages)
            Toggle("邮件", isOn: $draft.readMail)
            Toggle("微信收到的文件", isOn: $draft.readWeChatFiles)
            Toggle("日历与提醒事项", isOn: Binding(
                get: { draft.showCalendar },
                set: { enabled in
                    guard enabled else { draft.showCalendar = false; return }
                    Task {
                        // Ask for calendar access right away, so the result is visible here.
                        draft.showCalendar = await model.enableCalendar()
                    }
                }
            ))
            Toggle("热点", isOn: $draft.collectNews)
        }
    }

    private var shortcutsSection: some View {
        Section("快捷") {
            Toggle("自动复制验证码", isOn: $draft.autoCopyCodes)
            Toggle("建议回复", isOn: $draft.suggestReplies)
        }
    }

    private var recognitionSection: some View {
        Section("识别") {
            TextField(text: $draft.userNames, prompt: Text("小明, Ming")) {
                Text("我的称呼")
                Text("用来判断是否 @ 我")
            }
            ForEach(draft.rules) { rule in
                LabeledContent {
                    IconButton(symbol: "xmark", help: "删除") { draft.rules.removeAll { $0.id == rule.id } }
                } label: {
                    Text(rule.text)
                    Text(rule.summary)
                }
            }
            HStack(spacing: 8) {
                TextField("", text: $newRule, prompt: Text("新规则，如：王总的消息都标紧急"))
                    .textFieldStyle(.plain)
                    .onSubmit(addRule)
                if addingRule {
                    ProgressView().controlSize(.small)
                } else {
                    Button("添加", action: addRule)
                        .buttonStyle(PillButtonStyle())
                        .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if ruleFailed {
                Text("没能理解，换个说法试试").font(.system(size: 11.5)).foregroundStyle(Theme.caution)
            }
        }
    }

    private func addRule() {
        let text = newRule
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !addingRule else { return }
        addingRule = true
        ruleFailed = false
        Task {
            if let rule = await model.addRule(text) {
                draft.rules.append(rule)
                newRule = ""
            } else {
                ruleFailed = true
            }
            addingRule = false
        }
    }

    private var ignoredSection: some View {
        Section("忽略") {
            ForEach(draft.ignoredAppIDs, id: \.self) { id in
                LabeledContent {
                    Button("恢复") { draft.ignoredAppIDs.removeAll { $0 == id } }
                        .buttonStyle(PillButtonStyle())
                } label: {
                    Label {
                        Text(AppDirectory.shared.name(for: id))
                    } icon: {
                        AppIcon(bundleID: id, size: 18)
                    }
                }
            }
            ForEach(draft.mutedConversations, id: \.self) { key in
                LabeledContent {
                    Button("恢复") { draft.mutedConversations.removeAll { $0 == key } }
                        .buttonStyle(PillButtonStyle())
                } label: {
                    Label {
                        Text(key.title)
                        Text(AppDirectory.shared.name(for: key.appID))
                    } icon: {
                        AppIcon(bundleID: key.appID, size: 18)
                    }
                }
            }
            if !draft.irrelevantExamples.isEmpty {
                LabeledContent {
                    Button("清除") { draft.irrelevantExamples.removeAll() }
                        .buttonStyle(PillButtonStyle())
                } label: {
                    Text("标为不相关")
                    Text("\(draft.irrelevantExamples.count) 条")
                }
            }
            AppPicker(recent: model.recentApps, excluded: Set(draft.ignoredAppIDs)) { id in
                draft.ignoredAppIDs.append(id)
            }
        }
    }

    private var searchSection: some View {
        Section {
            Toggle(isOn: $draft.webSearch) {
                Text("提问时联网搜索")
                if draft.provider.hasNativeWebSearch {
                    Text("使用模型自带搜索")
                } else if !draft.provider.supportsToolCalls {
                    Text("需 OpenAI 兼容协议")
                }
            }
            .disabled(!draft.provider.hasNativeWebSearch && !draft.provider.supportsToolCalls)
            if draft.webSearch && !draft.provider.hasNativeWebSearch && draft.provider.supportsToolCalls {
                Picker("渠道", selection: $draft.searchChannel) {
                    ForEach(WebSearchChannel.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: draft.searchChannel) { _, _ in searchTestResult = nil }
                searchKeyRow
                HStack(spacing: 8) {
                    Button(testingSearch ? "测试中…" : "测试搜索", action: testSearch)
                        .buttonStyle(PillButtonStyle())
                        .disabled(testingSearch)
                    if testingSearch { ProgressView().controlSize(.small) }
                    if let searchTestResult {
                        Text(searchTestResult)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
            }
        } header: {
            Text("联网搜索")
        }
    }

    private var searchKeyBinding: Binding<String> {
        Binding(get: { searchKeys[draft.searchChannel] ?? "" },
                set: { searchKeys[draft.searchChannel] = $0; searchTestResult = nil })
    }

    @ViewBuilder
    private var searchKeyRow: some View {
        let channel = draft.searchChannel
        let label = channel == .baidu ? "千帆 Key" : "DeepSeek Key"
        let key = searchKeys[channel] ?? ""
        if editingSearchKey.contains(channel) || key.isEmpty {
            SecureField(label, text: searchKeyBinding,
                        prompt: Text(draft.provider.sharesKey(with: channel) ? "默认同模型 Key" : "粘贴 Key"))
        } else {
            LabeledContent(label) {
                HStack(spacing: 6) {
                    Text(Self.masked(key))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Button("更换") {
                        searchKeys[channel] = ""
                        editingSearchKey.insert(channel)
                    }
                    .buttonStyle(PillButtonStyle())
                    IconButton(symbol: "xmark", help: "清除") { searchKeys[channel] = "" }
                }
            }
        }
    }

    private func testSearch() {
        testingSearch = true
        searchTestResult = nil
        let channel = draft.searchChannel
        let key = searchKeys[channel] ?? ""
        let provider = draft.provider
        let modelKey = apiKey
        Task {
            searchTestResult = await model.testSearch(channel: channel, channelKey: key, provider: provider, modelKey: modelKey)
            testingSearch = false
        }
    }

    private var modelSection: some View {
        Section {
            LabeledContent("预设") {
                Menu("选择") {
                    ForEach(ProviderPreset.all) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Picker("协议", selection: $draft.provider.apiProtocol) {
                ForEach(APIProtocol.allCases) { Text($0.displayName).tag($0) }
            }
            TextField("接口地址", text: $draft.provider.baseURL, prompt: Text("https://api.example.com/v1"))
            TextField("模型", text: $draft.provider.model, prompt: Text("模型名称"))
            apiKeyRow
            if draft.provider.apiProtocol == .openAICompatible && draft.provider.isLocal {
                Toggle(isOn: $draft.provider.reasoning) {
                    Text("深度思考")
                    Text("更准确，稍慢")
                }
            }
            HStack(spacing: 8) {
                Button(testing ? "测试中…" : "测试连接", action: test)
                    .buttonStyle(PillButtonStyle())
                    .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("AI 模型")
        } footer: {
            Label(draft.provider.isLocal
                  ? "仅在本机处理"
                  : "通知将发送至 \(draft.provider.secretAccount)",
                  systemImage: draft.provider.isLocal ? "lock.fill" : "exclamationmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(draft.provider.isLocal ? Theme.textSecondary : Theme.caution)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var apiKeyRow: some View {
        if editingKey || apiKey.isEmpty {
            SecureField("API Key", text: $apiKey, prompt: Text(draft.provider.isLocal ? "可留空" : "粘贴 Key"))
        } else {
            LabeledContent("API Key") {
                HStack(spacing: 6) {
                    Text(Self.masked(apiKey))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Button("更换") {
                        apiKey = ""
                        editingKey = true
                    }
                    .buttonStyle(PillButtonStyle())
                    IconButton(symbol: "xmark", help: "清除") { apiKey = "" }
                }
            }
        }
    }

    /// "sk-••••a1b2"
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: 6) }
        let prefix = key.hasPrefix("sk-") ? "sk-" : String(key.prefix(2))
        return prefix + "••••" + key.suffix(4)
    }

    private func load() {
        draft = model.settings
        apiKey = model.apiKey(for: draft.provider)
        editingKey = apiKey.isEmpty
        searchKeys = Dictionary(uniqueKeysWithValues: WebSearchChannel.allCases.map { ($0, model.searchKey(for: $0)) })
        editingSearchKey = []
    }

    private func apply(_ preset: ProviderPreset) {
        draft.provider = preset.configuration
        apiKey = model.apiKey(for: preset.configuration)
        editingKey = apiKey.isEmpty
        testResult = nil
    }

    private func save() {
        model.setAPIKey(apiKey, for: draft.provider)
        for channel in WebSearchChannel.allCases { model.setSearchKey(searchKeys[channel] ?? "", for: channel) }
        model.settings = draft
        model.route = .main
        model.checkNow()
    }

    private func test() {
        testing = true
        testResult = nil
        let configuration = draft.provider
        let key = apiKey
        let names = draft.userNameList
        Task {
            testResult = await model.testConnection(configuration: configuration, apiKey: key, userNames: names)
            testing = false
        }
    }
}

/// "添加应用" menu: apps that sent notifications recently first, then everything else.
private struct AppPicker: View {
    let recent: [String]
    let excluded: Set<String>
    let pick: (String) -> Void
    @State private var all: [AppDirectory.Entry] = []

    var body: some View {
        Menu("添加应用") {
            let recentIDs = recent.filter { !excluded.contains($0) }.prefix(12)
            if !recentIDs.isEmpty {
                Section("最近") {
                    ForEach(Array(recentIDs), id: \.self) { id in
                        item(id: id, name: AppDirectory.shared.name(for: id))
                    }
                }
            }
            let mac = all.filter { !$0.isIPhone && !excluded.contains($0.id) }
            let iPhone = all.filter { $0.isIPhone && !excluded.contains($0.id) }
            if !mac.isEmpty {
                Menu("Mac") {
                    ForEach(mac) { item(id: $0.id, name: $0.name) }
                }
            }
            if !iPhone.isEmpty {
                Menu("iPhone") {
                    ForEach(iPhone) { item(id: $0.id, name: $0.name) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task {
            all = await Task.detached(priority: .utility) { AppDirectory.shared.pickableApps() }.value
        }
    }

    private func item(id: String, name: String) -> some View {
        Button {
            pick(id)
        } label: {
            if let icon = AppDirectory.shared.smallIcon(for: id) {
                Label { Text(name) } icon: { Image(nsImage: icon) }
            } else {
                Text(name)
            }
        }
    }
}
