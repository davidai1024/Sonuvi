// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI
import Charts

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var runtime: RuntimeManager
    @State private var key = ""
    @State var message = ""
    @ObservedObject var usage: UsageStore
    @State var period = 7
    @State private var helpOpen = false
    var tab: String { model.settingsTab }
    @State private var runningApps: [NSRunningApplication] = []
    init(model: AppModel) { self.model = model; self.runtime = model.runtime; self.usage = model.usage }
    let tabs = [("通用", "slider.horizontal.3"), ("翻译", "character.bubble"), ("朗读", "waveform"), ("模型", "cpu"), ("统计", "chart.bar.xaxis"), ("快捷键", "command")]
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tab).font(MuseLayout.pageTitle)
                        Text(subtitle).font(MuseLayout.body).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MuseLayout.contentInset).padding(.top, 26).padding(.bottom, 18)
                    ScrollView {
                        VStack(alignment: .leading, spacing: MuseLayout.sectionGap) {
                            if tab == "通用" { general }
                            else if tab == "翻译" { translation }
                            else if tab == "朗读" { speech }
                            else if tab == "模型" { models }
                            else if tab == "统计" { statistics }
                            else { hotkeys }
                        }.padding(.horizontal, MuseLayout.contentInset).padding(.bottom, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.id(tab)
                    if tab != "统计" || !message.isEmpty {
                        HStack(spacing: 12) {
                            Text(message).font(MuseLayout.detail).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 8)
                            if tab != "统计" { Button("保存设置") { save() }.buttonStyle(.bordered).controlSize(.regular).keyboardShortcut("s", modifiers: .command) }
                        }.frame(minHeight: 32).padding(.horizontal, MuseLayout.contentInset).padding(.vertical, 10)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.font(MuseLayout.body).frame(minWidth: 740, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
            .onAppear { model.refreshStatus(); refreshApps() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 36).accessibilityHidden(true)
            HStack(spacing: 9) {
                BrandIcon(size: 28)
                Text("Sonuvi").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 28).padding(.top, 12).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("偏好设置").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 2)
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, entry in
                        if index == 4 { Text("使用").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 2) }
                        Button { model.settingsTab = entry.0; usage.touch(); message = "" } label: {
                            HStack(spacing: 8) {
                                SidebarIcon(symbol: entry.1, color: sidebarColors[index])
                                Text(entry.0).font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 10).frame(height: MuseLayout.sidebarRow)
                                .background(tab == entry.0 ? Color.primary.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(MuseHoverStyle(radius: 10)).help(subtitles[entry.0] ?? entry.0)
                            .accessibilityAddTraits(tab == entry.0 ? [.isSelected] : [])
                    }
                }
            }
            Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " · 本机版").font(MuseLayout.caption).foregroundStyle(.tertiary).padding(12)
        }.padding(.horizontal, 8).frame(width: MuseLayout.sidebarWidth)
            .museGlass(18)
            .padding(.leading, MuseLayout.windowInset).padding(.vertical, MuseLayout.windowInset)
    }
    let sidebarColors: [Color] = [.gray, .blue, .purple, .orange, .green, .pink]
    let subtitles = ["通用": "外观、使用习惯与权限", "翻译": "中英互译规则", "朗读": "声音与语速", "模型": "DeepSeek 与本地模型", "统计": "用量、趋势与成就", "快捷键": "自定义全局快捷键"]
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
            Text(title).font(MuseLayout.sectionTitle)
            if !detail.isEmpty { Text(detail).font(MuseLayout.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.cyan)
        }
    }
    func permissionRow(_ title: String, detail: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title, detail: detail, symbol: symbol) {
            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 18, height: 18).background(Color.green, in: Circle())
                    Text("已授权").font(MuseLayout.detail)
                }.foregroundStyle(.secondary).accessibilityElement(children: .combine).accessibilityLabel(title + "已授权")
            } else { Button("去授权", action: action).controlSize(.regular) }
        }
    }
    var general: some View {
        Group {
            rows("外观", detail: "选择界面的深浅色，或跟随 macOS。") {
                SettingsRow(title: "显示模式", detail: "更改后立即预览。", symbol: "circle.lefthalf.filled") { AppearanceSegments(value: $model.appearance) }
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
            rows("权限", detail: "按需开启，授权完成后自动更新状态。") {
                permissionRow("辅助功能", detail: "读取你主动选中的文字。", symbol: "hand.raised", granted: model.permissionGranted) {
                    if !model.previewMode { SelectionReader.openPermissionSettings() }
                }
                rowDivider
                permissionRow("屏幕录制", detail: "仅用于主动发起的截图翻译。", symbol: "viewfinder", granted: model.screenPermission) {
                    guard !model.previewMode else { message = "预览窗口不申请权限。"; return }
                    if UserDefaults.standard.bool(forKey: "screenPermissionRequested") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    } else {
                        UserDefaults.standard.set(true, forKey: "screenPermissionRequested")
                        _ = CGRequestScreenCaptureAccess()
                    }
                    model.screenPermission = CGPreflightScreenCaptureAccess()
                }
            }
            rows("应用例外", detail: "在这些应用中隐藏划词按钮，快捷键仍然可用。") {
                ForEach(runningApps, id: \.processIdentifier) { app in
                    if let id = app.bundleIdentifier {
                        toggleRow(app.localizedName ?? id, detail: "", symbol: "app", value: Binding(get: { model.excludedApps.contains(id) }, set: { disabled in if disabled { if !model.excludedApps.contains(id) { model.excludedApps.append(id) } } else { model.excludedApps.removeAll { $0 == id } } }))
                    }
                }
                ForEach(model.excludedApps.filter { id in !runningApps.contains { $0.bundleIdentifier == id } }, id: \.self) { id in
                    SettingsRow(title: id, detail: "当前未运行", symbol: "app") { Button("移除") { model.excludedApps.removeAll { $0 == id } } }
                }
                HStack { Button("刷新应用列表") { refreshApps() }; Spacer() }.padding(16)
            }
        }
    }
    var translation: some View {
        Group {
            rows("翻译方向", detail: "根据原文自动识别语言。") {
                SettingsRow(title: "中文", detail: "中文单词、短语和句子。", symbol: "character") { Text("翻译成英文").foregroundStyle(.secondary) }
                rowDivider
                SettingsRow(title: "英文", detail: "英文单词、短语和句子。", symbol: "textformat.abc") { Text("翻译成中文").foregroundStyle(.secondary) }
            }
            rows("结果展示") {
                SettingsRow(title: "单词与短语", detail: "释义、词性、音标和双语例句。", symbol: "book.closed") { Text("词典卡片").foregroundStyle(.secondary) }
                rowDivider
                SettingsRow(title: "完整句子", detail: "流式显示译文，保留段落。", symbol: "text.alignleft") { Text("译文卡片").foregroundStyle(.secondary) }
            }
            Text("可以在翻译窗口手动切换展示方式。只有主动发起翻译时，原文才会发送至 DeepSeek。").font(MuseLayout.detail).foregroundStyle(.secondary)
        }
    }
    var speech: some View {
        Group {
            rows("声音", detail: "在本机自然朗读英文。") {
                SettingsRow(title: "音色", detail: "选择喜欢的口音和声音。", symbol: "waveform") {
                    Picker("音色", selection: $model.voice) { Text("Heart · 美音女声").tag("af_heart"); Text("Bella · 美音女声").tag("af_bella"); Text("Lily · 英音女声").tag("bf_lily"); Text("George · 英音男声").tag("bm_george"); Text("Michael · 美音男声").tag("am_michael") }.labelsHidden().frame(width: 170)
                }
                rowDivider
                SettingsRow(title: "语速", detail: "从 0.5 倍到 2 倍。", symbol: "speedometer") {
                    HStack(spacing: 8) { Slider(value: $model.speed, in: 0.5...2, step: 0.05).frame(width: 110); Text(String(format: "%.2f×", model.speed)).monospacedDigit().frame(width: 42) }
                }
            }
            rows("播放") {
                toggleRow("自动朗读", detail: "翻译完成后，自动读出英文。", symbol: "play.circle", value: $model.autoRead)
                rowDivider
                SettingsRow(title: "试听声音", detail: "使用当前音色和语速。", symbol: "speaker.wave.2") { Button(model.speaking ? "停止" : "试听") { model.speak("Hello David. Let's practice English together.", presentation: .settings) } }
            }
        }
    }
    var models: some View {
        Group {
            rows("DeepSeek", detail: "中英互译使用你的 API Key。") {
                SettingsRow(title: "API Key", detail: model.hasKey ? "已安全保存在钥匙串。" : "尚未配置。", symbol: "key", stacked: true) {
                    HStack {
                        SecureField(model.previewMode ? "外观预览，不填写 Key" : (model.hasKey ? "填写新的 Key 以替换" : "输入 API Key"), text: $key).textFieldStyle(.roundedBorder).disabled(model.previewMode)
                        Button("删除") { KeyStore.delete(); model.refreshStatus(); message = "Key 已删除" }.disabled(!model.hasKey || model.previewMode)
                    }
                }
                rowDivider
                SettingsRow(title: "模型", detail: "关闭思考，流式返回。", symbol: "cpu") { TextField("模型名称", text: $model.modelName).textFieldStyle(.roundedBorder).frame(width: 180) }
            }
            rows("本地朗读", detail: "首次准备完成后，可离线使用。") {
                SettingsRow(title: "Kokoro", detail: runtime.status, symbol: "waveform") {
                    if runtime.installing || runtime.removing { ProgressView().controlSize(.small) }
                    else { Image(systemName: runtime.ready ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(.secondary) }
                }
                rowDivider
                HStack(spacing: 10) {
                    if runtime.installing { Button("取消") { runtime.cancel() } }
                    else {
                        if runtime.canImport { Button(runtime.ready ? "重新导入" : "导入现有模型") { model.stopSpeaking(); runtime.install(importExisting: true) } }
                        Button(runtime.ready ? "重新下载" : "下载模型") { model.stopSpeaking(); runtime.install(importExisting: false) }
                    }
                    Spacer(minLength: 0)
                }.disabled(runtime.removing || model.previewMode).padding(16)
                if runtime.ready {
                    HStack { Button("查看模型文件") { runtime.reveal() }; Spacer(); Button("移除独立环境") { confirmRemove() }.disabled(runtime.installing || runtime.removing || model.previewMode) }.padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
        }
    }
    var hotkeys: some View {
        Group {
            rows("全局快捷键", detail: "点击右侧框录制，成功后立即生效并保存。") {
                shortcutRow("翻译选中文字", symbol: "character.bubble", index: 0)
                rowDivider
                shortcutRow("朗读／停止", symbol: "speaker.wave.2", index: 1)
                rowDivider
                shortcutRow("截图翻译", symbol: "viewfinder", index: 2)
            }
            HStack(alignment: .top) {
                Text("Control、Option 或 Command 搭配字母或数字。按 Esc 取消录制。").font(MuseLayout.detail).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") { applyShortcuts([.translate, .read, .ocr]) }
            }
            if !model.hotkeysReady { Text("快捷键尚未就绪，可能与其他应用冲突。").font(MuseLayout.detail).foregroundStyle(.secondary) }
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
        return SettingsRow(title: title, detail: "", symbol: symbol) { ShortcutRecorder(value: binding, onRecording: { model.recordingShortcut = $0 }).frame(width: 140, height: 30).accessibilityLabel(title + "快捷键") }
    }
    func refreshApps() { runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != nil }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") } }
    func confirmRemove() {
        let alert = NSAlert(); alert.messageText = "移除独立朗读环境？"; alert.informativeText = "模型及其运行环境会移到废纸篓。之后可以重新导入或下载，翻译功能不受影响。"; alert.addButton(withTitle: "移到废纸篓"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.stopSpeaking(); runtime.remove() }
    }
    func save() {
        guard !model.previewMode else { message = "外观预览不保存真实设置。"; return }
        do {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { try KeyStore.save(value); key = "" }
            if model.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.modelName = "deepseek-flash" }
            try model.savePreferences(); model.refreshStatus(); message = "已保存"
        } catch { message = error.localizedDescription }
    }
}

struct SelectionBubble: View {
    let translate: () -> Void
    let read: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: translate) { Text("译").font(.system(size: 14, weight: .semibold)).frame(width: 37, height: 34) }.help("中英互译")
            Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 14)
            Button(action: read) { Image(systemName: "speaker.wave.2.fill").font(.system(size: 12)).frame(width: 37, height: 34) }.help("朗读英文")
        }.buttonStyle(MuseHoverStyle(radius: 10)).padding(4).museGlass(14, interactive: true)
    }
}
