// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, shortcuts, voice, translation, ready
    var tag: String { ["欢迎", "权限", "快捷键", "本地朗读", "翻译", "准备就绪"][rawValue] }
    var title: String { ["让文字开口，\n让理解更自然。", "解锁你的\n整个 Mac。", "随时划选，\n一键开始。", "小模型，\n自然的声音。", "连接翻译，\n跨越两种语言。", "一切就绪，\n开始使用 Sonuvi。"][rawValue] }
    var detail: String { [
        "在任何应用中划选文字，即可中英互译，\n或用自然的声音，听一段英文。",
        "开启以下两项权限，让划词和截图翻译\n随时可用。授权后，请回到这里继续。",
        "保留默认组合，或录制你习惯的快捷键。\n无论在哪个应用，都能快速翻译与朗读。",
        "内置 Kokoro 82M。8,200 万参数，\n在你的 Mac 上运行，英文朗读无需联网。",
        "中文译为英文，英文译为中文。\n连接你的 DeepSeek API，即可开始翻译。",
        "在任意应用里选中文字，按下快捷键。\nSonuvi 会一直在菜单栏，等你需要时出现。"
    ][rawValue] }
}

@MainActor
final class OnboardingState: ObservableObject {
    static let version = 1
    let defaults: UserDefaults
    @Published private(set) var step: OnboardingStep
    @Published private(set) var completed: Bool
    @Published private(set) var replaying: Bool
    @Published var error = ""
    var awaitingPermissionReturn: Bool { defaults.bool(forKey: "onboarding.permissionReturn") }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        replaying = defaults.bool(forKey: "onboarding.replaying")
        completed = defaults.integer(forKey: "onboarding.completedVersion") >= Self.version
        step = defaults.bool(forKey: "onboarding.permissionReturn") ? .permissions :
            (OnboardingStep(rawValue: defaults.integer(forKey: "onboarding.step")) ?? .welcome)
    }
    func go(_ next: OnboardingStep) {
        step = next; error = ""
        defaults.set(next.rawValue, forKey: "onboarding.step")
        if next != .permissions { defaults.set(false, forKey: "onboarding.permissionReturn") }
        defaults.synchronize()
    }
    func preparePermissionReturn() {
        go(.permissions)
        defaults.set(true, forKey: "onboarding.permissionReturn")
        defaults.synchronize()
    }
    func restart() {
        replaying = true; defaults.set(true, forKey: "onboarding.replaying"); go(.welcome)
    }
    func cancelReplay() {
        guard completed && replaying else { return }
        replaying = false; defaults.set(false, forKey: "onboarding.replaying"); go(.welcome)
    }
    func finish() {
        replaying = false; defaults.set(false, forKey: "onboarding.replaying")
        completed = true
        defaults.set(Self.version, forKey: "onboarding.completedVersion")
        defaults.set(false, forKey: "onboarding.permissionReturn")
        defaults.synchronize()
    }
    static func mayContinue(_ step: OnboardingStep, accessibility: Bool, screen: Bool, shortcuts: Bool, voice: Bool, api: Bool) -> Bool {
        switch step {
        case .permissions: return accessibility && screen
        case .shortcuts: return shortcuts
        case .voice: return voice
        case .translation: return api
        default: return true
        }
    }
}

struct VoiceOption: Identifiable {
    let id: String
    var name: String { String(id.dropFirst(3)).capitalized }
    var accent: String { id.hasPrefix("b") ? "英音" : "美音" }
    var gender: String { id.dropFirst().first == "f" ? "女声" : "男声" }
    var label: String { "\(name) · \(L10n.text(accent))\(L10n.text(gender))" }
}

enum VoiceCatalog {
    // All 28 English voices from the model's VOICES.md, not a curated subset.
    static let all: [VoiceOption] = ("af_heart af_bella af_nicole af_alloy af_aoede af_jessica af_kore af_nova af_river af_sarah af_sky am_adam am_echo am_eric am_fenrir am_liam am_michael am_onyx am_puck am_santa bf_emma bf_alice bf_isabella bf_lily bm_george bm_daniel bm_fable bm_lewis").split(separator: " ").map { VoiceOption(id: String($0)) }
    static func option(_ id: String) -> VoiceOption { all.first { $0.id == id } ?? all[0] }
}

struct VoicePicker: View {
    @Binding var selection: String
    var body: some View {
        Picker(L10n.text("音色"), selection: $selection) {
            Section(L10n.text("美式英语 · 20 个音色")) {
                ForEach(VoiceCatalog.all.filter { $0.id.hasPrefix("a") }) { LText($0.label).tag($0.id) }
            }
            Section(L10n.text("英式英语 · 8 个音色")) {
                ForEach(VoiceCatalog.all.filter { $0.id.hasPrefix("b") }) { LText($0.label).tag($0.id) }
            }
        }.labelsHidden()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: OnboardingState
    @ObservedObject var runtime: RuntimeManager
    let requestPermission: (Bool) -> Void
    let restart: () -> Void
    let complete: () -> Void
    let dismiss: () -> Void
    @State private var apiKey = ""
    @State private var selectedShortcut = 0
    @State private var pressedGlyphs: [String] = []
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    private let coral = Color(red: 1, green: 0.37, blue: 0.40)
    init(model: AppModel, state: OnboardingState, requestPermission: @escaping (Bool) -> Void, restart: @escaping () -> Void, complete: @escaping () -> Void, dismiss: @escaping () -> Void = {}) {
        self.model = model; self.state = state; self.runtime = model.runtime
        self.requestPermission = requestPermission; self.restart = restart; self.complete = complete; self.dismiss = dismiss
    }
    private var voiceReady: Bool { runtime.ready && model.selectedVoiceAvailable }
    private var canContinue: Bool {
        OnboardingState.mayContinue(state.step, accessibility: model.permissionGranted, screen: model.screenPermission,
            shortcuts: model.hotkeysReady && !model.recordingShortcut, voice: voiceReady, api: model.hasKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 42) {
                    introduction.frame(width: max(290, geometry.size.width * 0.34), alignment: .leading)
                    OnboardingCenteredScroll { content }
                        .id(state.step)
                }.padding(.horizontal, 44).padding(.top, 58).padding(.bottom, 18)
                footer.padding(.horizontal, 20).padding(.bottom, 18).padding(.top, 8)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.frame(minWidth: 900, minHeight: 600)
            .background((scheme == .dark ? Color(red: 0.025, green: 0.027, blue: 0.030) : Color(nsColor: .windowBackgroundColor)).opacity(0.94))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: state.step)
            .onChange(of: state.step) { _ in model.stopSpeaking(); pressedGlyphs = [] }
            .onChange(of: model.voice) { _ in model.stopSpeaking() }
            .onChange(of: model.speed) { _ in model.stopSpeaking() }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L10n.text("界面语言"), selection: $model.language) {
                ForEach(AppLanguage.allCases, id: \.self) { LText($0.label).tag($0) }
            }.labelsHidden().frame(width: 155, alignment: .leading).padding(.bottom, 4)
            LText(state.step.tag).font(.system(size: 12, weight: .medium)).foregroundStyle(coral)
                .padding(.horizontal, 9).padding(.vertical, 5).background(coral.opacity(0.10), in: Capsule())
            LText(state.step.title).font(.system(size: 32, weight: .semibold)).tracking(-0.6).lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            LText(state.step.detail).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxHeight: .infinity, alignment: .center).accessibilityElement(children: .contain)
    }
    @ViewBuilder private var content: some View {
        VStack(spacing: 20) {
            switch state.step {
            case .welcome: welcome
            case .permissions: permissions
            case .shortcuts: shortcuts
            case .voice: voice
            case .translation: translation
            case .ready: ready
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(scheme == .dark ? 0.045 : 0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
    private func icon(_ symbol: String, color: Color, size: CGFloat = 36) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(.white)
            .frame(width: size, height: size).background(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.24))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.white.opacity(0.2)))
    }
    private var welcome: some View {
        VStack(spacing: 16) {
            card {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) { icon("character.bubble.fill", color: .blue); LText("选中文字，即刻理解").font(.system(size: 16, weight: .semibold)); Spacer() }
                    LText("Let curiosity lead the way.").font(.system(size: 21, weight: .medium)).padding(.vertical, 7).padding(.horizontal, 10)
                        .background(Color.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                    Divider().opacity(0.4)
                    LText("让好奇心带路。").font(.system(size: 21, weight: .medium))
                    LText("单词看释义，句子看译文。中英自动互译。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        icon("waveform", color: .purple)
                        LText("自然朗读").font(.system(size: 16, weight: .semibold))
                        LText("本地小模型，离线也能听。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        icon("viewfinder", color: .orange)
                        LText("截图翻译").font(.system(size: 16, weight: .semibold))
                        LText("无法选中？框选后识别文字。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func permission(_ title: String, detail: String, symbol: String, color: Color, granted: Bool, screen: Bool) -> some View {
        HStack(spacing: 16) {
            icon(symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                LText(title).font(.system(size: 16, weight: .medium))
                LText(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if granted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).frame(width: 16, height: 16).background(Color.green, in: Circle())
                    LText("已授权").font(.system(size: 12, weight: .medium))
                }.foregroundStyle(.secondary).frame(width: 96, height: 32)
                    .background(Color.primary.opacity(0.04), in: Capsule()).accessibilityLabel(L10n.text(title + "已授权"))
            } else {
                Button { requestPermission(screen) } label: { LText("去授权").font(.system(size: 12, weight: .medium)).frame(width: 96, height: 32).background(Color.primary.opacity(0.08), in: Capsule()) }
                    .buttonStyle(MuseHoverStyle(radius: 16)).accessibilityLabel(L10n.text("授权" + title))
            }
        }.frame(minHeight: 82)
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            permission("辅助功能", detail: "读取你主动选中的文字，用于划词翻译与朗读。", symbol: "accessibility", color: .blue, granted: model.permissionGranted, screen: false)
            Divider().opacity(0.35)
            permission("屏幕录制", detail: "仅在你主动截图翻译时，识别框选区域。", symbol: "viewfinder", color: .purple, granted: model.screenPermission, screen: true)
            Divider().opacity(0.35)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                LText("只处理你主动选择的内容，不会持续录屏。权限状态会自动刷新，下一步由你决定。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(.top, 4)
            VStack(alignment: .leading, spacing: 10) {
                    LText(model.permissionGranted && model.screenPermission ? "授权已就绪，点击「继续」前往下一步。" : "已在系统设置中开启，但状态仍未更新？")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button(L10n.text("重启并检查")) { restart() }
                        Button(L10n.text(model.permissionRepairing ? "正在修复…" : "重新配置权限")) { model.repairPermissions?() }
                            .help(L10n.text("清理本应用的辅助功能和屏幕录制记录并重启，随后重新授权。"))
                    }.controlSize(.regular).disabled(model.permissionRepairing)
                    LText("重启后会自动回到本页。请在权限就绪后手动继续。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .opacity(model.permissionGranted && model.screenPermission ? 0 : 1)
                        .accessibilityHidden(model.permissionGranted && model.screenPermission)
                }.frame(height: 88, alignment: .topLeading).padding(.top, 8)
                    .opacity(state.awaitingPermissionReturn ? 1 : 0)
                    .accessibilityHidden(!state.awaitingPermissionReturn)
        }.padding(.horizontal, 4)
    }
    private func shortcut(_ title: String, symbol: String, color: Color, index: Int) -> some View {
        let binding = Binding<ShortcutSpec>(get: { [model.translateShortcut, model.readShortcut, model.ocrShortcut][index] }, set: { spec in
            var values = [model.translateShortcut, model.readShortcut, model.ocrShortcut]; values[index] = spec
            do { try model.applyShortcuts(values); state.error = "" } catch { state.error = error.localizedDescription }
        })
        return HStack(spacing: 14) {
            icon(symbol, color: color)
            LText(title).font(.system(size: 15, weight: .medium))
            Spacer(minLength: 8)
            ShortcutRecorder(value: binding, isSelected: selectedShortcut == index, onRecording: { model.recordingShortcut = $0 },
                onSelect: { selectedShortcut = index; pressedGlyphs = [] }, onPressed: { pressedGlyphs = $0 })
                .frame(width: 116, height: 32)
                .accessibilityLabel(L10n.text(title + "快捷键"))
        }.padding(.horizontal, 10).frame(height: 66)
            .background(selectedShortcut == index ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle()).onTapGesture { selectedShortcut = index; pressedGlyphs = [] }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShortcutKeyPreview(value: [model.translateShortcut, model.readShortcut, model.ocrShortcut][selectedShortcut], pressed: pressedGlyphs).padding(.bottom, 20)
            shortcut("翻译选中文字", symbol: "character.bubble.fill", color: .blue, index: 0)
            Divider().opacity(0.35)
            shortcut("朗读／停止", symbol: "waveform", color: .purple, index: 1)
            Divider().opacity(0.35)
            shortcut("截图翻译", symbol: "viewfinder", color: .orange, index: 2)
            LText(model.recordingShortcut ? "正在录制：按下组合键，松开保存；按 Esc 或点击其他位置取消。" : (model.hotkeysReady ? "点击右侧组合键即可录制。三个快捷键需互不相同。" : "快捷键与其他应用冲突，请换一个组合键后继续。"))
                .font(.system(size: 12)).foregroundStyle(model.recordingShortcut ? Color.accentColor : Color.secondary)
                .frame(height: 36, alignment: .topLeading).padding(.top, 10)
        }
    }
    private var voice: some View {
        VStack(spacing: 16) {
            card {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        icon("waveform", color: .purple, size: 44)
                        VStack(alignment: .leading, spacing: 5) {
                            LText("Kokoro 82M").font(.system(size: 18, weight: .semibold))
                            LText("28 个英文音色 · 完全本地运行").font(.system(size: 12)).foregroundStyle(.secondary)
                        }; Spacer()
                        if runtime.installing { ProgressView().controlSize(.small) }
                        else { Image(systemName: runtime.ready ? "checkmark.circle.fill" : "arrow.clockwise.circle").foregroundStyle(runtime.ready ? Color.green : .secondary) }
                    }
                    HStack(spacing: 12) {
                        LText(runtime.ready ? "模型已就绪。英文内容留在你的 Mac 上。" : runtime.status)
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.text("准备本地模型")) {
                            runtime.preparePreferred()
                        }.disabled(voiceReady || runtime.installing)
                            .opacity(voiceReady || runtime.installing ? 0 : 1)
                            .accessibilityHidden(voiceReady || runtime.installing)
                    }.frame(height: 32)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        LText("默认音色").font(.system(size: 13, weight: .medium)); Spacer()
                        VoicePicker(selection: $model.voice).frame(width: 215)
                    }
                    HStack(spacing: 12) {
                        LText("默认语速").font(.system(size: 13, weight: .medium))
                        Slider(value: $model.speed, in: 0.5...2, step: 0.05).tint(.purple)
                        LText(String(format: "%.2f×", model.speed)).font(.system(size: 12)).monospacedDigit().frame(width: 45)
                    }
                    Divider().opacity(0.4)
                    HStack(spacing: 12) {
                        ZStack(alignment: .leading) {
                            LText(model.error.isEmpty ? "Find a voice that feels like you." : model.error).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).opacity(model.speaking ? 0 : 1)
                            if model.speaking { HStack(spacing: 8) { SpeechDots(meter: model.playback.meter); LText(model.readingStatus ?? "正在朗读").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) } }
                        }.frame(height: 30)
                        Spacer(minLength: 0)
                        Button(L10n.text(model.speaking ? "停止试听" : "试听声音")) { model.speak("Find a voice that feels like you. Welcome to Sonuvi, your little companion for reading and understanding English.", presentation: .settings) }
                            .disabled(!voiceReady).controlSize(.regular).frame(width: 120)
                    }.frame(minHeight: 30)
                }
            }
        }
    }
    private var translation: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                LText("文").font(.system(size: 32, weight: .medium)).frame(width: 72, height: 72).museGlass(18)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 23)).foregroundStyle(.secondary)
                LText("A").font(.system(size: 34, weight: .medium)).frame(width: 72, height: 72).museGlass(18)
            }.padding(.bottom, 12)
            card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) { icon("key.fill", color: .blue); LText("DeepSeek API").font(.system(size: 16, weight: .semibold)); Spacer() }
                    if model.keyAccessRequired {
                        LText("API Key 已保存，需要重新允许钥匙串访问。")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        Button(L10n.text("允许访问 API Key")) {
                            do { try model.authorizeAPIKeyAccess(); state.error = "" }
                            catch { state.error = error.localizedDescription }
                        }.disabled(model.previewMode)
                    }
                    LText(model.hasKey ? "已配置 API Key。可保留现有配置，或输入新 Key 替换。" : "填入自己的 API Key，开启中英互译。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).frame(height: 32, alignment: .topLeading)
                    APIKeyField(placeholder: L10n.text(model.hasKey ? "输入新的 API Key 以替换" : "sk-…"), text: $apiKey, bordered: false).frame(height: 22).font(.system(size: 13)).padding(12)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel(L10n.text("DeepSeek API Key")).disabled(model.previewMode)
                    HStack {
                        LText(model.previewMode ? "外观预览不保存真实设置。" : "安全保存在 macOS 钥匙串").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Spacer()
                        Link(L10n.text("获取 API Key ↗"), destination: URL(string: "https://platform.deepseek.com/api_keys")!).font(.system(size: 12))
                    }
                }
            }
            LText("仅在你发起翻译时向 DeepSeek 发送原文。\n本地朗读不需要 API Key，可稍后在设置中配置翻译。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var ready: some View {
        VStack(spacing: 28) {
            BrandIcon(size: 94)
            HStack(spacing: 10) {
                ForEach(Array(keyGlyphs.enumerated()), id: \.offset) { _, glyph in keycap(glyph, width: 68) }
            }
            VStack(spacing: 10) {
                LText("选中文字，按 \(model.translateShortcut.label) 翻译").font(.system(size: 16, weight: .medium))
                LText("\(model.readShortcut.label) 朗读   ·   \(model.ocrShortcut.label) 截图翻译").font(.system(size: 13)).foregroundStyle(.secondary)
                LText(model.hasKey ? "翻译已配置，可以开始中英互译。" : "翻译尚未配置。你现在可以直接使用本地英文朗读。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10).lineLimit(2).frame(height: 42)
            }
        }.frame(maxWidth: .infinity)
    }
    private var keyGlyphs: [String] { model.translateShortcut.label.map(String.init) }
    private func keycap(_ label: String, width: CGFloat, pressed: Bool = false) -> some View {
        LText(label).font(.system(size: 29, weight: .medium)).foregroundStyle(pressed ? coral : Color.secondary)
            .frame(width: width, height: 70).background(LinearGradient(colors: [pressed ? coral.opacity(0.18) : Color.primary.opacity(0.025), pressed ? coral.opacity(0.26) : Color.primary.opacity(0.07)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.14)))
            .shadow(color: pressed ? coral.opacity(0.20) : .black.opacity(0.08), radius: pressed ? 7 : 3, y: pressed ? 1 : 3).offset(y: pressed ? 2 : 0)
    }
    private var footer: some View {
        HStack(spacing: 16) {
            Button { if let previous = OnboardingStep(rawValue: state.step.rawValue - 1) { state.go(previous) } } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium)).frame(width: 36, height: 36).background(Color.primary.opacity(0.07), in: Circle())
            }.buttonStyle(MuseHoverStyle(radius: 18)).disabled(state.step == .welcome).accessibilityLabel(L10n.text("上一步"))
            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Capsule().fill(step == state.step ? coral : Color.primary.opacity(0.12)).frame(width: step == state.step ? 36 : 13, height: 3)
                }
            }.accessibilityLabel(L10n.text("第 \(state.step.rawValue + 1) 步，共 6 步"))
            Spacer(minLength: 8)
            LText(state.error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 240).frame(height: 36)
            if state.replaying && state.completed {
                Button(L10n.text("返回设置")) { state.cancelReplay(); dismiss() }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                    .disabled(model.recordingShortcut)
            }
            if state.step == .translation {
                Button(L10n.text("稍后设置")) { apiKey = ""; state.go(.ready) }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            Button(action: advance) {
                HStack(spacing: 10) {
                    LText(state.step == .ready ? "开始使用 Sonuvi" : state.step == .translation ? "保存并继续" : state.step == .welcome ? "开始设置" : "继续").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "return").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }.padding(.horizontal, 19).frame(height: 36).background(Color.primary.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09)))
            }.buttonStyle(MuseHoverStyle(radius: 18)).disabled(!canContinue).keyboardShortcut(.return, modifiers: [])
        }.frame(height: 40)
    }
    private func advance() {
        guard canContinue else { return }
        if state.step == .translation {
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                do { try model.saveAPIKey(value); apiKey = "" }
                catch { state.error = error.localizedDescription; return }
            }
        }
        if state.step == .voice, !model.previewMode { model.saveVoicePreferences() }
        if state.step == .ready {
            if !model.permissionGranted || !model.screenPermission { state.go(.permissions); return }
            if !model.hotkeysReady { state.go(.shortcuts); return }
            if !voiceReady { state.go(.voice); return }
            model.stopSpeaking(); state.finish(); complete()
        } else if let next = OnboardingStep(rawValue: state.step.rawValue + 1) { state.go(next) }
    }
}

// The scroll document fills its actual viewport, centering short pages. Long
// pages retain their intrinsic height and scroll from the top without clipping.
struct OnboardingCenteredScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                content().frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: max(0, viewport.size.height - 16), alignment: .center)
                    .padding(.vertical, 8)
            }.scrollIndicators(.hidden)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
