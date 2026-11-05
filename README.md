# 拾穗 Gleaner

**从通知里拾起要紧的事。**

拾穗是一个常驻 macOS 菜单栏的小工具。它读取 Mac 上所有应用的通知（微信、企业微信、邮件、短信……），用大模型从群聊闲聊、营销推送这些噪音里，挑出真正需要你处理的事，列成一份待办清单。

```
菜单栏：  🌾 3 处理打卡异常

          ┌──────────────────────────────────────────┐
          │ 拾穗  3 件待处理        今天已分析 128 条 │
          ├──────────────────────────────────────────┤
          │ ● 处理 11 月 3 日打卡异常                 │
          │   企业微信  打卡  5 分钟前                │
          │   回复王总方案的提交时间                  │
          │   微信  项目群  12 分钟前  截止今天       │
          │   验证码 482913（某某云）                 │
          │   信息  106900  刚刚                      │
          └──────────────────────────────────────────┘
```

> 状态：早期原型（0.1.0）。功能可用，但接口和数据格式还可能变化。

## 功能

- **自动收集**：监听 Mac 的通知，以及从 iPhone 转发到 Mac 的通知（macOS 15+ 的"iPhone 通知"功能），增量读取，重启后从上次的位置继续
- **邮件**：直接读取「邮件」应用里所有账号的收件箱（本地索引和正文），不依赖通知；邮件里的验证码同样立即提取
- **@ 规则**：群里 @ 了别人的消息直接跳过；@ 你或 @ 所有人的正常提醒；谁都没 @ 的群消息只作为"值得关注"
- **验证码优先**：验证码用规则识别，不等模型分析就立即显示
- **AI 筛选**：识别有人问你、@ 你、需要你审批或回复、打卡异常、截止任务等事项，忽略与你无关的群聊、寒暄和推送；同一件事的多条消息合并成一条
- **菜单栏提醒**：显示待办数量和最紧急的一件事；点开可以跳转到对应应用，或标记完成
- **会话记录**：按会话在本机保存最近 7 天的消息（微信只有对方的消息，短信 / iMessage 包含双方），用于下面几项
- **建议回复**：结合会话上下文给出可直接发送的回复，可编辑后复制
- **会话摘要与提问**：一键总结某个群或联系人最近聊了什么；提问页支持多轮对话和历史会话，会按问题检索 7 天内的记录，需要时联网搜索（模型自带搜索，或 DeepSeek / 百度渠道）
- **加到日程**：带时间的事项一键加到「提醒事项」或「日历」，到点由系统提醒
- **记录空档**：记下各应用在前台的时段（如正开着微信时不会有通知），摘要和回答会注明哪段记录可能不全
- **一句话规则**：如"王总的消息都标紧急""周末不提醒工作群"，由模型理解一次，之后由代码执行
- **热点浏览**：从新闻、热搜、行情类通知中整理出事件标题，放在单独的"热点"标签页；过滤营销推广和点赞评论，同一事件合并，保留 24 小时，不计入待办
- **模型自由**：支持 **OpenAI 兼容协议**（本地 Ollama、DeepSeek、通义千问、OpenAI 等）和 **Anthropic 协议**（Claude 及兼容服务），地址、模型名和 Key 都可以自己配置

## 隐私

拾穗需要读取你的全部通知，其中可能包括聊天内容。所以：

- 所有处理都在本机完成，拾穗**没有自己的服务器**
- 默认使用**本地模型**（Ollama），通知内容不会离开这台 Mac
- 如果切换到云端模型，通知内容会发送到你配置的服务商，设置页会明确提示
- API Key 保存在系统钥匙串中
- 读取通知时会先把数据库复制到临时目录，读完立即删除；只保存提炼出的待办事项

## 系统要求

- macOS 14 或更高版本
- **完全磁盘访问权限**：通知数据库位于受保护的目录，没有公开 API 可以读取其他应用的通知
- 一个大模型：推荐本地运行 [Ollama](https://ollama.com) + `qwen3:30b-a3b`（约 18GB，32GB 以上内存；关闭深度思考即可）

## 安装

1. 从 [Releases](../../releases/latest) 下载最新的 `Gleaner-版本号.dmg`，打开后把「拾穗」拖进「应用程序」。
2. 第一次打开时系统会提示无法验证开发者（拾穗没有经过 Apple 公证）。打开「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」。只需要这一次。
3. 点菜单栏的 🌾，按引导授予**完全磁盘访问权限**，再在设置里选一个模型预设、填上 API Key。

之后有新版本时，拾穗会自动提示，点一下即可更新，授权不受影响。

## 从源码构建

### 1. 准备本地模型（可选）

```bash
# 安装 Ollama 后
ollama pull qwen3:30b-a3b
```

也可以跳过这一步，在设置里改用云端服务。

### 2. 构建

需要 Xcode 或 Command Line Tools（Swift 6）。

```bash
git clone <repo-url> Gleaner && cd Gleaner
scripts/build-app.sh          # 生成 build/拾穗.app
```

### 3. 安装、授权并运行

```bash
scripts/install.sh            # 安装到 /Applications 并启动，首次启动会开启开机自启
```

点击菜单栏的 🌾，按提示给"拾穗"授予**完全磁盘访问权限**（系统设置 → 隐私与安全性）。

**关于签名**：macOS 按代码签名识别应用的隐私授权。`build-app.sh` 会优先使用钥匙串里的 Apple Development / Developer ID 证书（也可以用环境变量 `GLEANER_SIGN_IDENTITY` 指定），这样重新安装后授权依然有效；没有证书时会使用临时签名，每次重新安装都需要重新授权。

开发时也可以直接在终端运行调试版：

```bash
scripts/run-dev.sh
```

这种方式下文件访问权限算在终端（或编辑器）头上，给终端授权一次即可。

### 4. 配置

点击菜单栏的 🌾 → 齿轮图标：

| 预设 | 协议 | 接口地址 | 默认模型 |
|---|---|---|---|
| 本地 Ollama | OpenAI 兼容 | `http://127.0.0.1:11434/v1` | `qwen3:30b-a3b` |
| Claude | Anthropic | `https://api.anthropic.com` | `claude-opus-5-5` |
| DeepSeek | OpenAI 兼容 | `https://api.deepseek.com` | `deepseek-flash` |
| 通义千问 | OpenAI 兼容 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus` |

填好后点"测试连接"，会用 3 条示例通知试跑一次。建议同时填上"我的称呼"，帮助模型识别哪些消息是 @ 你的。

## 项目结构

```
Sources/
  GleanerCore/                 与界面无关的核心逻辑，可独立测试
    Models/                    AppNotification、ActionItem
    Sources/                   NotificationSource 协议；Mac 通知、iPhone 转发通知、组合数据源
    LLM/                       LLMProvider 协议；OpenAI 兼容、Anthropic 两种实现
    Extraction/                提示词、ActionExtractor、NewsCurator、@ 判断、验证码识别、ReplyWriter（默认关闭）
    Pipeline/                  NotificationPipeline：增量读取、去重、分批、断点续跑
    Support/                   SecretStore（钥匙串）、JSONFileStore
  Gleaner/                     SwiftUI 菜单栏应用
Tests/GleanerCoreTests/        单元测试（Swift Testing）
scripts/                       构建与运行脚本
```

数据流：

```
NotificationSource ──新通知──▶ NotificationPipeline ──分批──▶ ActionExtractor ──▶ LLMProvider
                                      │                              │
                                 进度持久化                     ActionItem ──▶ 菜单栏
```

## 扩展

**接入新的通知来源**（例如 IMAP 邮箱、日历）：实现 `NotificationSource`：

```swift
public protocol NotificationSource: Sendable {
    func changeToken() -> Date?                                 // 有变化时返回不同的值
    func fetch(after date: Date) throws -> [AppNotification]   // 按时间升序返回
}
```

**接入新的模型协议**：实现 `LLMProvider`，并在 `APIProtocol` / `ProviderConfiguration.makeProvider` 中注册：

```swift
public protocol LLMProvider: Sendable {
    func complete(_ request: CompletionRequest) async throws -> String
}
```

**调整识别规则**：修改 `Sources/GleanerCore/Extraction/ExtractionPrompt.swift`。

**用真实环境验证**（可选，需要设置环境变量才会运行）：

```bash
# 用本地模型跑一组示例通知，检查识别效果
GLEANER_LIVE_BASE_URL=http://127.0.0.1:11434/v1 GLEANER_LIVE_MODEL=qwen3:30b-a3b scripts/swiftw test --filter "LiveModelTests|LiveNewsCurationTests"
# 读取本机真实的 iPhone 转发通知，只输出各应用的数量
GLEANER_LIVE_IPHONE=1 scripts/swiftw test --filter LiveIPhoneSourceTests
```

## 开发

```bash
scripts/swiftw build      # 编译
scripts/swiftw test       # 运行测试
scripts/run-dev.sh        # 构建调试版并运行
```

`scripts/swiftw` 是对 `swift` 命令的薄包装。从 macOS 27 SDK 开始，SwiftUI 的 `@State` 改由宏实现，而宏插件只随 Xcode 提供、Command Line Tools 里没有。如果检测到这种情况，`swiftw` 会自动改用一个不需要宏插件的已安装 SDK。装了 Xcode 时，它等同于直接运行 `swift`。

### 发布新版本

发版用自签名证书签名、Sparkle 推送更新，一条命令完成：

```bash
scripts/release.sh 0.2.0 [更新说明.md]
```

它会更新版本号、编译签名、打包 DMG、生成签名过的更新清单 `appcast.xml`，提交代码并在 GitHub 上创建 Release。已安装的拾穗从 `releases/latest/download/appcast.xml` 检查更新。

第一次发版前需要：

- 签名证书：`scripts/make-signing-cert.sh`，会在 `~/.gleaner-signing` 留一份备份。**这份证书要一直用下去**，换了证书，用户的授权会失效，也收不到更新
- Sparkle 工具：把 [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0) 的压缩包解压到 `.tools/sparkle-2.10.0`，再运行 `.tools/sparkle-2.10.0/bin/generate_keys --account gleaner` 生成更新密钥，把输出的公钥填进 `Resources/Info.plist` 的 `SUPublicEDKey`。私钥同样要备份（`generate_keys --account gleaner -x 文件`）
- `gh auth login` 登录仓库所在的 GitHub 账号

## 已知限制

- 通知数据库没有公开文档，macOS 大版本更新后可能需要适配；iPhone 转发通知的存储格式同样如此
- iPhone 转发的通知只在通知中心里保留，在手机或 Mac 上清除后，拾穗就读不到了
- 应用设置成"不显示通知内容"时，拾穗只能看到"你收到了一条消息"
- 被设为静音、或关闭了通知的应用和群聊，不会进入通知数据库
- 依赖完全磁盘访问权限，无法上架 Mac App Store

## 许可证

[MIT](LICENSE)
