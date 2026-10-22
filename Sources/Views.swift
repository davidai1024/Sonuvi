// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI
import Charts

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var runtime: RuntimeManager
    @ObservedObject var browser: BrowserIntegration
    @State private var key = ""
    @State private var replacingKey = false
    @State var message = ""
    @ObservedObject var usage: UsageStore
    @State var period = 7
    @State private var selectedShortcut = 0
    @State private var pressedShortcutGlyphs: [String] = []
    @State private var helpOpen = false
    var tab: String { model.settingsTab }
    @State private var runningApps: [NSRunningApplication] = []
    @State private var configuredAppIDs: [String] = []
    init(model: AppModel) { self.model = model; self.runtime = model.runtime; self.browser = model.browser; self.usage = model.usage }
    let tabs = [("通用", "slider.horizontal.3"), ("权限", "lock.shield"), ("翻译", "character.bubble"), ("朗读", "waveform"), ("模型", "cpu"), ("统计", "chart.bar.xaxis"), ("快捷键", "command")]
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        LText(tab).font(MuseLayout.pageTitle)
                        LText(subtitle).font(MuseLayout.body).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MuseLayout.contentInset).padding(.top, 26).padding(.bottom, 18)
                    ScrollView {
                        VStack(alignment: .leading, spacing: MuseLayout.sectionGap) {
                            if model.keyAccessRequired || !model.keyAccessIssue.isEmpty { keyAccessNotice }
                            if tab == "通用" { general }
                            else if tab == "权限" { permissions }
                            else if tab == "翻译" { translation }
                            else if tab == "朗读" { speech }
                            else if tab == "模型" { models }
                            else if tab == "统计" { statistics }
                            else { hotkeys }
                        }.padding(.horizontal, MuseLayout.contentInset).padding(.bottom, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.id(tab)
                    if !message.isEmpty || !model.preferenceError.isEmpty {
                        HStack(spacing: 12) {
                            LText(model.preferenceError.isEmpty ? message : model.preferenceError).font(MuseLayout.detail).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 8)
                        }.frame(minHeight: 32).padding(.horizontal, MuseLayout.contentInset).padding(.vertical, 10)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.font(MuseLayout.body).frame(minWidth: 740, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
            .onAppear { model.refreshStatus(); refreshApps() }
    }
    private var keyAccessNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text(model.keyAccessRequired ? "翻译需要重新授权" : "暂时无法读取 API Key"), systemImage: "key.fill")
                .font(.system(size: 14, weight: .semibold))
            LText(model.keyAccessRequired ? "API Key 仍保存在钥匙串中。更新或重装后，macOS 可能要求重新允许访问；无需重新填写 Key。本地英文朗读不受影响。" : "暂时无法读取钥匙串中的 API Key。请解锁登录钥匙串后重新检查；无需删除或重新填写 Key。")
                .font(MuseLayout.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.keyAccessIssue.isEmpty {
                LText(model.keyAccessIssue).font(MuseLayout.detail).foregroundStyle(.secondary)
            }
            Button(L10n.text(model.keyAccessRequired ? "允许访问 API Key" : "重新检查")) {
                if model.keyAccessRequired {
                    do { try model.authorizeAPIKeyAccess(); message = "钥匙串访问已授权，可以返回翻译。" }
                    catch { message = error.localizedDescription }
                } else { model.refreshAPIKeyAccess() }
            }.disabled(model.previewMode)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 36).accessibilityHidden(true)
            HStack(spacing: 9) {
                BrandIcon(size: 28)
                LText("Sonuvi").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 28).padding(.top, 12).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    LText("偏好设置").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 2)
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, entry in
                        if entry.0 == "统计" { LText("使用").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 2) }
                        Button { model.settingsTab = entry.0; usage.touch(); message = "" } label: {
                            HStack(spacing: 8) {
                                SidebarIcon(symbol: entry.1, color: sidebarColors[index])
                                LText(entry.0).font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 10).frame(height: MuseLayout.sidebarRow)
                                .background(tab == entry.0 ? Color.primary.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(MuseHoverStyle(radius: 10)).help(L10n.text(subtitles[entry.0] ?? entry.0))
                            .accessibilityAddTraits(tab == entry.0 ? [.isSelected] : [])
                    }
                }
            }
            LText((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " · 本机版").font(MuseLayout.caption).foregroundStyle(.tertiary).padding(12)
        }.padding(.horizontal, 8).frame(width: MuseLayout.sidebarWidth)
            .museGlass(18)
            .padding(.leading, MuseLayout.windowInset).padding(.vertical, MuseLayout.windowInset)
    }
    let sidebarColors: [Color] = [.gray, .cyan, .blue, .purple, .orange, .green, .pink]
    let subtitles = ["通用": "外观与使用习惯", "权限": "管理划词与截图所需的系统授权", "翻译": "中英互译规则", "朗读": "声音与语速", "模型": "DeepSeek 与本地模型", "统计": "用量、趋势与成就", "快捷键": "自定义全局快捷键"]
    var subtitle: String { subtitles[tab] ?? "" }
    func section<Content: View>(_ title: String, detail: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(title, detail: detail)
            VStack(alignment: .leading, spacing: 14) { content() }.padding(MuseLayout.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsSurface())
        }
    }
    func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LText(title).font(MuseLayout.sectionTitle)
            if !detail.isEmpty { LText(detail).font(MuseLayout.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    func rows<Content: View>(_ title: String, detail: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(title, detail: detail)
            VStack(spacing: 0) { content() }.modifier(SettingsSurface())
        }
    }
    var rowDivider: some View { Divider().opacity(0.35).padding(.leading, 50).padding(.trailing, 16) }
    func toggleRow(_ title: String, detail: String, symbol: String, value: Binding<Bool>) -> some View {
        SettingsRow(title: title, detail: detail, symbol: symbol) {
            Toggle(L10n.text(title), isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.cyan)
        }
    }
    func permissionRow(_ title: String, detail: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title, detail: detail, symbol: symbol) {
            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 18, height: 18).background(Color.green, in: Circle())
                    LText("已授权").font(MuseLayout.detail)
                }.foregroundStyle(.secondary).accessibilityElement(children: .combine).accessibilityLabel(L10n.text(title + "已授权"))
            } else { Button(L10n.text("去授权"), action: action).controlSize(.regular) }
        }
    }
    private var permissionsReady: Bool { model.permissionGranted && model.screenPermission }
    var permissions: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: permissionsReady ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(LinearGradient(colors: permissionsReady ? [.green, .teal] : [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: (permissionsReady ? Color.green : .blue).opacity(0.22), radius: 12, y: 4)
                VStack(alignment: .leading, spacing: 8) {
                    LText(model.permissionRepairing ? "正在准备重新授权" : permissionsReady ? "权限已就绪" : "先授权，再开始使用")
                        .font(.system(size: 20, weight: .semibold))
                    LText(model.permissionRepairing ? "正在清理旧权限记录，完成后将自动返回此页。" : permissionsReady ? "划词翻译、自然朗读和截图翻译，已经准备好了。" : "开启辅助功能与屏幕录制，才能完整使用划词翻译、朗读和截图翻译。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if model.permissionRepairing { ProgressView().controlSize(.small) }
                        else { Image(systemName: permissionsReady ? "checkmark.circle.fill" : "hand.raised.fill") }
                        LText(model.permissionRepairing ? "正在处理…" : "只处理你主动选择的文字与截图")
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(permissionsReady ? Color.green : Color.blue).padding(.top, 4)
                }
                Spacer(minLength: 0)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [(permissionsReady ? Color.green : .blue).opacity(0.10), Color.primary.opacity(0.015)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
                .museGlass(20)
            PermissionMigrationNotice(model: model)
            rows("权限", detail: "按需开启，授权完成后自动更新状态。") {
                permissionRow("辅助功能", detail: "读取你主动选中的文字。", symbol: "hand.raised", granted: model.permissionGranted) {
                    model.requestPermission?(false)
                }
                rowDivider
                permissionRow("屏幕录制", detail: "仅用于主动发起的截图翻译。", symbol: "viewfinder", granted: model.screenPermission) {
                    model.requestPermission?(true)
                }
                if (!model.permissionGranted || !model.screenPermission) && (UserDefaults.standard.bool(forKey: "screenPermissionRequested") || UserDefaults.standard.bool(forKey: "accessibilityPermissionRequested")) {
                    HStack { LText("已授权但状态未更新？").font(MuseLayout.detail).foregroundStyle(.secondary); Spacer(); Button(L10n.text("重启并检查")) { model.restartApplication?() } }.padding(16)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                LText("授权异常时，可清理本应用的两项旧权限记录。应用会自动重启并返回这里。")
                    .font(MuseLayout.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L10n.text(model.permissionRepairing ? "正在修复…" : "重新配置权限")) { model.repairPermissions?() }
                    .disabled(model.permissionRepairing).fixedSize()
            }
            if !model.permissionMessage.isEmpty { LText(model.permissionMessage).font(MuseLayout.detail).foregroundStyle(.secondary) }
        }.disabled(model.permissionRepairing)
    }
    var general: some View {
        Group {
            rows("外观", detail: "选择界面的深浅色，或跟随 macOS。") {
                SettingsRow(title: "显示模式", detail: "更改后立即生效并保存。", symbol: "circle.lefthalf.filled") { AppearanceSegments(value: $model.appearance) }
                rowDivider
                SettingsRow(title: "界面语言", detail: "更改后立即生效，不影响中英互译方向。", symbol: "globe") {
                    Picker(L10n.text("界面语言"), selection: $model.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { LText($0.label).tag($0) }
                    }.labelsHidden().frame(width: 155)
                }
            }
            rows("使用习惯", detail: "让划词翻译按照你的习惯工作。") {
                toggleRow("登录时启动", detail: "登录 Mac 后自动准备好。", symbol: "power", value: $model.loginEnabled)
                rowDivider
                toggleRow("窗口置顶", detail: "翻译结果保持在其他窗口上方。", symbol: "pin", value: $model.keepOnTop)
                rowDivider
                toggleRow("划词按钮", detail: "选中文字后显示翻译和朗读入口。", symbol: "cursorarrow.rays", value: $model.mouseLookup)
                rowDivider
                toggleRow("复制取词", detail: "无法直接读取选区时尝试复制。", symbol: "doc.on.clipboard", value: $model.clipboardFallback)
            }
            rows("浏览器右键菜单", detail: "在 Chrome / Edge 主右键菜单中使用翻译和朗读。") {
                SettingsRow(title: "Sonuvi 浏览器扩展", detail: browser.enabled ? "本机连接已启用。加载扩展后即可使用。" : "先启用本机连接，再下载并加载浏览器扩展。", symbol: "globe") {
                    HStack(spacing: 8) {
                        Button(L10n.text("下载扩展")) { NSWorkspace.shared.open(BrowserIntegration.extensionURL) }
                        Button(L10n.text(browser.enabled ? "关闭连接" : "启用连接")) {
                            do {
                                if browser.enabled { try browser.disable(); message = "浏览器连接已关闭。" }
                                else { try browser.enable(); message = "连接已启用。请加载浏览器扩展后使用。" }
                            }
                            catch { message = error.localizedDescription }
                        }
                    }.disabled(model.previewMode)
                }
            }
            rows("使用引导", detail: "重新查看功能介绍、权限、快捷键与音色设置，现有配置会保留。") {
                SettingsRow(title: "重新运行引导", detail: "可随时退出并返回设置。", symbol: "sparkles") {
                    Button(L10n.text("开始引导")) { model.restartOnboarding?() }.disabled(model.previewMode)
                }
            }
            rows("应用更新") { AppUpdateSettings(updates: model.updates) }
            rows("各应用的划词菜单", detail: "开启后，在对应应用中划选文字会显示翻译和朗读菜单；关闭后隐藏菜单。快捷键不受影响，修改立即生效。") {
                if !model.mouseLookup { LText("划词按钮总开关已关闭；开启后，以下设置才会生效。").font(MuseLayout.detail).foregroundStyle(.secondary).padding(16) }
                ForEach(runningApps, id: \.processIdentifier) { app in
                    if let id = app.bundleIdentifier { appSelectionRow(id, name: app.localizedName ?? id, running: true) }
                }
                ForEach(configuredAppIDs.filter { id in !runningApps.contains { $0.bundleIdentifier == id } }, id: \.self) { id in
                    appSelectionRow(id, name: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id, running: false)
                }
            }
        }
    }
    var translation: some View {
        Group {
            rows("翻译方向", detail: "根据原文自动识别语言。") {
                SettingsRow(title: "中文", detail: "中文单词、短语和句子。", symbol: "character") { LText("翻译成英文").foregroundStyle(.secondary) }
                rowDivider
                SettingsRow(title: "英文", detail: "英文单词、短语和句子。", symbol: "textformat.abc") { LText("翻译成中文").foregroundStyle(.secondary) }
            }
            rows("结果展示") {
                SettingsRow(title: "单词与短语", detail: "释义、词性、音标和双语例句。", symbol: "book.closed") { LText("词典卡片").foregroundStyle(.secondary) }
                rowDivider
                SettingsRow(title: "完整句子", detail: "流式显示译文，保留段落。", symbol: "text.alignleft") { LText("译文卡片").foregroundStyle(.secondary) }
            }
            LText("可以在翻译窗口手动切换展示方式。只有主动发起翻译时，原文才会发送至 DeepSeek。").font(MuseLayout.detail).foregroundStyle(.secondary)
        }
    }
    var speech: some View {
        Group {
            rows("声音", detail: "在本机自然朗读英文。") {
                SettingsRow(title: "音色", detail: "选择喜欢的口音和声音。", symbol: "waveform") {
                    VoicePicker(selection: $model.voice).frame(width: 195)
                }
                rowDivider
                SettingsRow(title: "语速", detail: "从 0.5 倍到 2 倍。", symbol: "speedometer") {
                    HStack(spacing: 8) { Slider(value: $model.speed, in: 0.5...2, step: 0.05).frame(width: 110); LText(String(format: "%.2f×", model.speed)).monospacedDigit().frame(width: 42) }
                }
            }
            rows("播放") {
                toggleRow("自动朗读", detail: "翻译完成后，自动读出英文。", symbol: "play.circle", value: $model.autoRead)
                rowDivider
                SettingsRow(title: "试听声音", detail: "使用当前音色和语速。", symbol: "speaker.wave.2") { Button(L10n.text(model.speaking ? "停止" : "试听")) { model.speak("Welcome to Sonuvi. Let's explore English together.", presentation: .settings) } }
            }
        }
    }
    var models: some View {
        Group {
            rows("DeepSeek", detail: "中英互译使用你的 API Key。") {
                if model.hasKey && !replacingKey {
                    SettingsRow(title: "API Key", detail: model.keyAccessRequired ? "已保存，等待允许访问。" : "已安全保存在钥匙串。", symbol: "key") {
                        HStack(spacing: 10) {
                            Text(model.keyPreview.isEmpty ? "••••••••" : model.keyPreview)
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                            Menu {
                                Button(L10n.text("替换成新的")) { key = ""; replacingKey = true; message = "" }
                                Button(L10n.text("删除"), role: .destructive) {
                                    do { try model.deleteAPIKey(); key = ""; message = "Key 已删除" }
                                    catch { message = error.localizedDescription }
                                }
                            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 20) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                                .accessibilityLabel(L10n.text("API Key 更多操作")).help(L10n.text("更多操作"))
                                .disabled(model.previewMode)
                        }
                    }
                } else {
                    SettingsRow(title: "API Key", detail: "回车或移开焦点保存，Esc 取消。", symbol: "key", stacked: true) {
                        HStack(spacing: 10) {
                            APIKeyField(placeholder: L10n.text(model.previewMode ? "外观预览，不填写 Key" : "输入 API Key"), text: $key,
                                onCommit: commitKey, onCancel: cancelKey)
                                .frame(height: 28).disabled(model.previewMode)
                        }
                    }
                }
                rowDivider
                SettingsRow(title: "模型", detail: "关闭思考，流式返回。", symbol: "cpu") { TextField(L10n.text("模型名称"), text: $model.modelName, onEditingChanged: { editing in if !editing { normalizeModelName() } }).onSubmit(normalizeModelName).textFieldStyle(.roundedBorder).frame(width: 180) }
            }
            rows("本地朗读", detail: "语音资源下载一次，之后无需联网；可独立更新。") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 17)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 28).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            LText("Kokoro · 82M").font(MuseLayout.sectionTitle)
                            if runtime.installing || runtime.removing { ProgressView().controlSize(.small) }
                            else { Image(systemName: runtime.ready ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(runtime.ready ? Color.green : Color.secondary)
                                .accessibilityLabel(L10n.text(runtime.ready ? "准备就绪" : "尚未下载")) }
                            Spacer(minLength: 8)
                            voiceModelActions
                        }.frame(minHeight: 28)
                        LText(runtime.displayStatus).font(MuseLayout.detail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
                if runtime.installing, let progress = runtime.downloadProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress).progressViewStyle(.linear)
                        LText(runtime.downloadDetail).font(MuseLayout.detail).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }
                if !runtime.ready && !runtime.installing {
                    LText("首次下载约 \(runtime.downloadSize)，包含运行环境与 28 个英文音色。更新 App 会保留已有模型。")
                        .font(MuseLayout.detail).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 16)
                }
                if !runtime.operationNotice.isEmpty {
                    LText(runtime.operationNotice).font(MuseLayout.detail).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 16)
                }
                if !model.error.isEmpty {
                    LText(model.error).font(MuseLayout.detail).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
        }
    }
    private var voiceModelActions: some View {
        HStack(spacing: 10) {
            if runtime.installing { Button(L10n.text("取消")) { runtime.cancel() } }
            else if runtime.ready && model.selectedVoiceAvailable {
                Button(L10n.text(model.speaking ? "停止试听" : "试听声音")) {
                    model.speak("Welcome to Sonuvi. A natural voice, ready whenever you need it.", presentation: .settings)
                }
                if model.speaking { SpeechDots(meter: model.playback.meter) }
                if runtime.modelUpdateAvailable {
                    Button(L10n.text("下载模型更新")) { model.stopSpeaking(); runtime.downloadVoicePackage() }
                }
            } else {
                Button(L10n.text(runtime.installationFailed ? "重试下载" : runtime.ready ? "修复朗读" : "下载本地模型")) {
                    model.stopSpeaking(); runtime.preparePreferred()
                }
            }
            Menu {
                Button(L10n.text(runtime.checkingForUpdates ? "正在检查…" : "检查模型更新")) { runtime.checkForModelUpdates() }
                    .disabled(runtime.checkingForUpdates)
                if runtime.ready {
                    Button(L10n.text("修复朗读")) { model.stopSpeaking(); runtime.preparePreferred() }
                    Button(L10n.text("查看模型文件")) { runtime.reveal() }
                    Divider()
                    Button(L10n.text("移除本地朗读环境…")) { confirmRemove() }
                }
                if runtime.installationFailed {
                    Button(L10n.text("重新下载语音资源")) { model.stopSpeaking(); runtime.downloadVoicePackage() }
                }
                if runtime.bundledRuntime == nil && runtime.canImport {
                    Button(L10n.text("导入旧版 Speak11 环境")) { model.stopSpeaking(); runtime.install(importExisting: true) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                .help(L10n.text("更多操作"))
                .disabled(runtime.installing || runtime.removing)
        }
        .disabled(runtime.removing || model.previewMode)
    }
    var hotkeys: some View {
        Group {
            ShortcutKeyPreview(value: [model.translateShortcut, model.readShortcut, model.ocrShortcut][selectedShortcut], pressed: pressedShortcutGlyphs)
            rows("全局快捷键", detail: "点击右侧框录制，成功后立即生效并保存。") {
                shortcutRow("翻译选中文字", symbol: "character.bubble", index: 0)
                rowDivider
                shortcutRow("朗读／停止", symbol: "speaker.wave.2", index: 1)
                rowDivider
                shortcutRow("截图翻译", symbol: "viewfinder", index: 2)
            }
            HStack(alignment: .top) {
                LText(model.recordingShortcut ? "正在录制：按下组合键，松开保存；按 Esc 或点击其他位置取消。" : "Control、Option 或 Command 搭配字母或数字。按 Esc 取消录制。").font(MuseLayout.detail).foregroundStyle(model.recordingShortcut ? Color.accentColor : Color.secondary).frame(height: 42, alignment: .topLeading)
                Spacer()
                Button(L10n.text("恢复默认")) { applyShortcuts([.translate, .read, .ocr]) }.disabled(model.recordingShortcut)
            }
            if !model.hotkeysReady { LText("快捷键尚未就绪，可能与其他应用冲突。").font(MuseLayout.detail).foregroundStyle(.secondary) }
        }
    }
    func applyShortcuts(_ values: [ShortcutSpec]) {
        do { try model.applyShortcuts(values); message = model.previewMode && !model.shortcutTestMode ? "预览已录制，未注册全局快捷键。" : "快捷键已生效并保存" }
        catch { message = error.localizedDescription }
    }
    func shortcutRow(_ title: String, symbol: String, index: Int) -> some View {
        let binding = Binding<ShortcutSpec>(get: { [model.translateShortcut, model.readShortcut, model.ocrShortcut][index] }, set: { value in
            var values = [model.translateShortcut, model.readShortcut, model.ocrShortcut]; values[index] = value; applyShortcuts(values)
        })
        return SettingsRow(title: title, detail: "", symbol: symbol) { ShortcutRecorder(value: binding, isSelected: selectedShortcut == index,
            onRecording: { model.recordingShortcut = $0 },
            onSelect: { selectedShortcut = index; pressedShortcutGlyphs = [] },
            onPressed: { pressedShortcutGlyphs = $0 }).frame(width: 116, height: 32).accessibilityLabel(L10n.text(title + "快捷键")) }
            .background(selectedShortcut == index ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle()).onTapGesture { selectedShortcut = index; pressedShortcutGlyphs = [] }
    }
    func appSelectionRow(_ id: String, name: String, running: Bool) -> some View {
        let enabled = model.showsSelectionMenu(in: id)
        let detail = (running ? "" : L10n.text("当前未运行") + " · ") + L10n.text(enabled ? "显示划词菜单" : "隐藏划词菜单")
        return SettingsRow(title: name, detail: detail, symbol: "app") {
            Toggle(L10n.text("显示划词菜单") + " · " + name, isOn: Binding(
                get: { model.showsSelectionMenu(in: id) },
                set: { model.setSelectionMenu($0, in: id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.cyan)
        }
    }
    func refreshApps() { configuredAppIDs = Array(Set(configuredAppIDs + model.excludedApps)).sorted(); runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != nil }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") } }
    func confirmRemove() {
        let alert = NSAlert(); alert.messageText = L10n.text("移除独立朗读环境？"); alert.informativeText = L10n.text("本地朗读环境会移到废纸篓。之后可从内置资源重新准备；翻译和已保存的设置不受影响。"); alert.addButton(withTitle: L10n.text("移到废纸篓")); alert.addButton(withTitle: L10n.text("取消"))
        if alert.runModal() == .alertFirstButtonReturn { model.stopSpeaking(); runtime.remove() }
    }
    private func normalizeModelName() {
        let value = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.modelName = value.isEmpty ? "deepseek-flash" : value
    }
    private func cancelKey() { key = ""; replacingKey = false }
    private func commitKey() {
        guard !model.previewMode else { return }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { try model.saveAPIKey(value); key = ""; replacingKey = false; message = "" }
        catch { message = error.localizedDescription }
    }
}

struct PermissionMigrationNotice: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.permissionMigrationPending {
            VStack(alignment: .leading, spacing: 10) {
                LText("系统开关已开，但仍无法使用？").font(.system(size: 13, weight: .semibold))
                LText("旧版的授权记录可能仍绑定旧签名。修复只清理当前不可用的 Sonuvi 权限，重启后再由你重新授权；设置、API Key 和模型都会保留。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(L10n.text(model.permissionRepairing ? "正在修复…" : "修复旧授权记录")) { model.repairStalePermissions?() }
                    Button(L10n.text("稍后处理")) { model.dismissPermissionMigration?() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.disabled(model.permissionRepairing)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct SelectionBubble: View {
    let translate: () -> Void
    let read: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: translate) { LText("译").font(.system(size: 14, weight: .semibold)).frame(width: 37, height: 34) }.help(L10n.text("中英互译"))
            Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 14)
            Button(action: read) { Image(systemName: "speaker.wave.2.fill").font(.system(size: 12)).frame(width: 37, height: 34) }.help(L10n.text("朗读英文"))
        }.buttonStyle(MuseHoverStyle(radius: 10)).padding(4).museGlass(14, interactive: true)
    }
}
