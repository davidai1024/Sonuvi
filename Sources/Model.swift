// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var source = "" {
        didSet { if oldValue != source { sourceApp = nil; cancel(); stopSpeaking(); result = ""; word = nil; error = "" } }
    }
    @Published var result = ""
    @Published var word: WordResult?
    @Published var inputKind: InputKind = .auto {
        didSet { if oldValue != inputKind { cancel(); result = ""; word = nil } }
    }
    @Published var busy = false
    @Published var error = ""
    @Published var recoverySettingsTab: String?
    @Published var speaking = false
    @Published var readingPresentation: ReadingPresentation = .inline
    let playback = SpeechPlayback()
    @Published var readingStatus: String? { didSet { onReadingStatusChanged?(readingStatus) } }
    var onReadingStatusChanged: ((String?) -> Void)?
    private var readingTranslation = false
    var readingActive: Bool { speaking || readingTranslation }
    @Published var toast = ""
    @Published var modelName = UserDefaults.standard.string(forKey: "modelName") ?? "deepseek-flash"
    @Published var voice = UserDefaults.standard.string(forKey: "voice") ?? "af_heart"
    @Published var speed = UserDefaults.standard.object(forKey: "speed") as? Double ?? 1.0
    @Published var mouseLookup = UserDefaults.standard.object(forKey: "mouseLookup") as? Bool ?? true
    @Published var autoRead = UserDefaults.standard.bool(forKey: "autoRead")
    @Published var permissionGranted = false
    @Published var permissionMessage = ""
    @Published var permissionRepairing = false
    @Published var keyAccessRequired = false
    @Published var screenPermission = false
    @Published var settingsTab = "通用"
    let usage = UsageStore()
    var sourceApp: String?
    @Published var hotkeysReady = false
    @Published var hasKey = false
    @Published var ocrBusy = false
    @Published var ocrRecognizing = false
    var cancelOCR: (() -> Void)?
    @Published var recordingShortcut = false { didSet { if oldValue != recordingShortcut { onShortcutRecording?(recordingShortcut) } } }
    @Published var statusText = ""
    @Published var appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system { didSet { applyAppearance() } }
    @Published var language = AppLocalization.shared.language {
        didSet {
            AppLocalization.shared.language = language
            if !previewMode { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
            onLanguageChanged?()
        }
    }
    var onLanguageChanged: (() -> Void)?
    @Published var loginEnabled = LoginManager.enabled
    @Published var keepOnTop = UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true { didSet { onWindowChanged?() } }
    @Published var excludedApps = UserDefaults.standard.stringArray(forKey: "excludedApps") ?? []
    @Published var clipboardFallback = UserDefaults.standard.object(forKey: "clipboardFallback") as? Bool ?? true
    @Published var translateShortcut = ShortcutSpec.load("translateShortcut", fallback: .translate)
    @Published var readShortcut = ShortcutSpec.load("readShortcut", fallback: .read)
    @Published var ocrShortcut = ShortcutSpec.load("ocrShortcut", fallback: .ocr)
    let runtime = RuntimeManager()
    var previewMode = false
    var onPreferences: (() -> String?)?
    var onShortcutRecording: ((Bool) -> Void)?
    var shortcutTestMode = false
    var onWindowChanged: (() -> Void)?
    var onTranslationHeightChanged: ((CGFloat) -> Void)?
    var startOCR: (() -> Void)?
    var openSettings: (() -> Void)?
    var hideWindow: (() -> Void)?
    var onLocalSelection: ((NSPoint, Int, Bool) -> Void)?
    var requestPermission: ((Bool) -> Void)?
    var repairPermissions: (() -> Void)?
    var restartApplication: (() -> Void)?
    var restartOnboarding: (() -> Void)?
    private var task: Task<Void, Never>?
    private var currentID = UUID()
    private var toastID = UUID()
    private var cache: [String: (String, WordResult?)] = [:]
    var effectiveKind: InputKind { inputKind == .auto ? TextRules.kind(source) : inputKind }
    var direction: Direction { TextRules.direction(source) }
    var englishText: String { direction == .toChinese ? source : (word?.translation ?? result) }
    var speechInstalled: Bool { runtime.availablePython != nil }
    var selectedVoiceAvailable: Bool {
        guard let info = RuntimeManager.info else { return false }
        return FileManager.default.fileExists(atPath: info.model + "/voices/" + VoiceCatalog.option(voice).id + ".safetensors")
    }
    func saveVoicePreferences() {
        UserDefaults.standard.set(voice, forKey: "voice")
        UserDefaults.standard.set(speed, forKey: "speed")
        if !previewMode { runtime.warmup() }
    }
    func saveAPIKey(_ value: String, store: (String) throws -> Void = KeyStore.save) throws {
        guard !previewMode else { throw TranslateError.message("外观预览不保存真实设置。") }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        try store(value)
        hasKey = true; keyAccessRequired = false
    }
    func authorizeAPIKeyAccess() throws {
        guard !previewMode else { return }
        _ = try KeyStore.read(allowInteraction: true)
        hasKey = true; keyAccessRequired = false
    }
    func deleteAPIKey() throws {
        guard !previewMode else { return }
        try KeyStore.delete(); hasKey = false; keyAccessRequired = false
    }

    func refreshStatus() { permissionGranted = SelectionReader.trusted; screenPermission = CGPreflightScreenCaptureAccess(); if !previewMode { hasKey = KeyStore.containsKey }; runtime.refresh() }
    func applyAppearance() {
        switch appearance { case .system: NSApp.appearance = nil; case .light: NSApp.appearance = NSAppearance(named: .aqua); case .dark: NSApp.appearance = NSAppearance(named: .darkAqua) }
    }
    func savePreferences() throws {
        let bindings = [translateShortcut, readShortcut, ocrShortcut]
        guard Set(bindings.map { "\($0.keyCode):\($0.modifiers)" }).count == 3 else { throw TranslateError.message("三个快捷键不能相同，请重新设置。") }
        if let issue = onPreferences?() { throw TranslateError.message(issue) }
        let defaults = UserDefaults.standard
        defaults.set(modelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "modelName")
        defaults.set(usage.enabled, forKey: "usageEnabled")
        defaults.set(voice, forKey: "voice"); defaults.set(speed, forKey: "speed")
        defaults.set(mouseLookup, forKey: "mouseLookup"); defaults.set(autoRead, forKey: "autoRead")
        defaults.set(appearance.rawValue, forKey: "appearance"); defaults.set(keepOnTop, forKey: "keepOnTop")
        defaults.set(excludedApps, forKey: "excludedApps"); defaults.set(clipboardFallback, forKey: "clipboardFallback")
        translateShortcut.store("translateShortcut"); readShortcut.store("readShortcut"); ocrShortcut.store("ocrShortcut")
        do { try LoginManager.apply(loginEnabled) }
        catch { loginEnabled = LoginManager.enabled; throw TranslateError.message("其他设置已保存。" + error.localizedDescription) }
    }
    func showsSelectionMenu(in bundleID: String) -> Bool { !excludedApps.contains(bundleID) }
    func setSelectionMenu(_ enabled: Bool, in bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
        if !enabled { excludedApps.append(bundleID) }
        if !previewMode { UserDefaults.standard.set(excludedApps, forKey: "excludedApps") }
    }
    func applyShortcuts(_ bindings: [ShortcutSpec]) throws {
        guard bindings.count == 3, Set(bindings.map { "\($0.keyCode):\($0.modifiers)" }).count == 3 else {
            throw TranslateError.message("三个快捷键不能相同，请重新设置。")
        }
        let old = [translateShortcut, readShortcut, ocrShortcut]
        translateShortcut = bindings[0]; readShortcut = bindings[1]; ocrShortcut = bindings[2]
        if !previewMode || shortcutTestMode {
            if let issue = onPreferences?() {
                translateShortcut = old[0]; readShortcut = old[1]; ocrShortcut = old[2]
                throw TranslateError.message(issue)
            }
            translateShortcut.store("translateShortcut"); readShortcut.store("readShortcut"); ocrShortcut.store("ocrShortcut")
        }
    }
    func setSource(_ text: String, app: String? = nil) {
        cancel(); stopSpeaking(); source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceApp = app
        result = ""; word = nil; error = ""; recoverySettingsTab = nil; inputKind = .auto
    }
    func showIssue(_ message: String, settingsTab: String? = nil) {
        error = message; recoverySettingsTab = settingsTab
    }
    func cancel() {
        if ocrBusy { cancelOCR?() }
        if readingTranslation { readingTranslation = false; readingStatus = nil }
        currentID = UUID(); task?.cancel(); task = nil; busy = false }
    func translate(readAfter: Bool = false, presentation: ReadingPresentation = .inline) {
        if previewMode { error = "此窗口仅用于界面预览。"; if readAfter { readingStatus = error }; return }
        cancel()
        if readAfter { readingPresentation = presentation; readingTranslation = true; readingStatus = "正在准备英文朗读…" }
        defer {
            if readAfter && !busy && !speaking && !error.isEmpty {
                readingTranslation = false; readingStatus = error
            }
        }
        result = ""; word = nil; error = ""; recoverySettingsTab = nil; statusText = ""
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = "请先划选或输入文字。"; return }
        guard text.count <= 6000 else { error = "单次最多 6000 个字符，请缩短后再翻译。"; return }
        let key: String
        do { key = try KeyStore.read(); keyAccessRequired = false }
        catch {
            if case KeyAccessError.authorizationRequired = error { keyAccessRequired = true }
            showIssue(error.localizedDescription, settingsTab: "模型"); return
        }
        let kind = effectiveKind
        let dir = direction
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = "\(model)|\(dir.rawValue)|\(kind.rawValue)|\(text)"
        if let cached = cache[cacheKey] { usage.translation(text: text, kind: kind, app: sourceApp, cached: true); result = cached.0; word = cached.1; if autoRead || readAfter { speak(presentation: readAfter ? presentation : .inline) }; return }
        let id = currentID
        let originApp = sourceApp
        usage.touch()
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let req = try DeepSeekClient.request(text: text, kind: kind, direction: dir, model: model, key: key)
                var output = ""
                for attempt in 0...1 {
                    do {
                        output = try await DeepSeekClient.stream(req) { [weak self] text in
                            guard let self, self.currentID == id else { return }
                            if kind == .sentence { self.result = text }
                        }
                        break
                    } catch TranslateError.retryable(let message) {
                        guard attempt == 0 else { throw TranslateError.message(message) }
                        self.statusText = "连接暂时中断，正在重试…"
                        try await Task.sleep(nanoseconds: 800_000_000)
                        try Task.checkCancellation()
                    }
                }
                try Task.checkCancellation()
                guard self.currentID == id else { return }
                if kind == .word { self.word = try WordResult.parse(output); self.result = self.word?.translation ?? "" }
                else { self.result = output }
                if self.cache.count >= 100 { self.cache.removeAll() }
                self.cache[cacheKey] = (self.result, self.word)
                self.usage.translation(text: text, kind: kind, app: originApp, cached: false)
                self.busy = false; self.statusText = ""
                if self.autoRead || readAfter { self.speak(presentation: readAfter ? presentation : .inline) }
            } catch {
                guard self.currentID == id, !Task.isCancelled else { return }
                self.busy = false; self.result = ""; self.word = nil
                if let error = error as? TranslateError { self.error = error.localizedDescription }
                else if error is DecodingError { self.error = "词典结果格式不完整，请重试或切换句子模式。" }
                else { self.error = "网络连接失败或超时，请检查网络后重试。" }
                if readAfter { self.readingTranslation = false; self.readingStatus = self.error }
            }
        }
    }
    func copy(_ value: String) {
        guard !value.isEmpty else { return }
        usage.copied()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        let id = UUID(); toastID = id; toast = "已复制"
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if toastID == id { toast = "" } }
    }
    func stopSpeaking() {
        if readingTranslation { cancel() }
        playback.stop(); speaking = false; readingStatus = nil
    }
    func speak(_ override: String? = nil, presentation: ReadingPresentation = .inline) {
        if speaking { stopSpeaking(); return }
        readingTranslation = false; readingPresentation = presentation
        error = ""; recoverySettingsTab = nil
        defer { if !speaking && !error.isEmpty { readingStatus = error } }
        let text = (override ?? englishText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = "请先翻译中文，再朗读英文译文。"; return }
        guard text.count <= 6000 else { error = "朗读内容过长，请缩短后再试。"; return }
        guard !runtime.installing else { error = "本地朗读环境正在准备，完成后即可朗读。"; return }
        if runtime.ready && !selectedVoiceAvailable { error = "所选音色尚未准备好，请在模型设置中修复朗读。"; return }
        guard let python = runtime.availablePython, let bridge = Bundle.main.url(forResource: "kokoro_bridge", withExtension: "py"), let service = Bundle.main.url(forResource: "kokoro_service", withExtension: "py") else { showIssue("请先在模型设置中导入或下载本地朗读模型。", settingsTab: "模型"); return }
        usage.touch()
        let readingApp = sourceApp
        do {
            let payload = try JSONSerialization.data(withJSONObject: ["text": text, "voice": voice, "speed": speed])
            speaking = true; readingStatus = "正在准备朗读…"
            try playback.start(python: python, bridge: bridge, service: service, payload: payload, phase: { [weak self] phase in
                self?.readingStatus = phase
            }, completion: { [weak self] outcome in
                guard let self else { return }; self.speaking = false
                switch outcome {
                case .success(let seconds):
                    self.readingStatus = nil
                    self.usage.reading(words: UsageStore.wordCount(text), seconds: seconds, app: readingApp)
                case .failure(let error):
                    self.error = error.localizedDescription; self.readingStatus = self.error
                }
            })
        } catch { playback.stop(); speaking = false; self.error = "无法启动本地朗读。" }
    }
}
