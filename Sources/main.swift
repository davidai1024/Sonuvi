// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI
import Carbon

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Accessory apps do not always route menu equivalents to the panel's
        // field editor. Give the focused text view the standard edit commands.
        if let editor = firstResponder as? NSTextView,
           TextEditingCommands.perform(event, in: editor) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
final class BubblePanel: NSPanel { override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false } }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    let shortcuts = GlobalShortcuts()
    var status: NSStatusItem!
    var window: FloatingPanel!
    var settings: NSWindow?
    var bubble: BubblePanel?
    let readingBar = ReadingBarController()
    let menuMotion = MenuMotion()
    var mouseMonitor: Any?
    var downMonitor: Any?
    var localMonitor: Any?
    var workspaceObserver: Any?
    var permissionTimer: Timer?
    var usageTimer: Timer?
    var mouseTask: Task<Void, Never>?
    var captureTask: Task<Void, Never>?
    var captureID = UUID()
    var mouseDown: NSPoint?
    var lookupSuppressedUntil = Date.distantPast
    var didReceiveService = false
    var ocrTask: Task<Void, Never>?
    let preview = CommandLine.arguments.contains("--preview") || (Bundle.main.object(forInfoDictionaryKey: "MusePreview") as? Bool == true)
    let shortcutTest = Bundle.main.object(forInfoDictionaryKey: "MuseShortcutTest") as? Bool == true

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !preview, let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.wusir.musetranslate").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(options: [.activateIgnoringOtherApps]); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        model.applyAppearance()
        let appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "退出 Sonuvi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(appItem)
        let edit = NSMenuItem(); edit.title = "编辑"; edit.submenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key) }
        appMenu.addItem(edit); NSApp.mainMenu = appMenu
        window = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 426, height: 480), styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Sonuvi"; window.isReleasedWhenClosed = false; window.isFloatingPanel = true; window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.backgroundColor = .clear; window.isOpaque = false
        window.minSize = NSSize(width: 360, height: 320)
        window.isMovableByWindowBackground = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        model.onReadingStatusChanged = { [weak self] message in
            guard let self else { return }
            self.readingBar.update(self.model.readingPresentation == .floating ? message : nil, isActive: self.model.readingActive, meter: self.model.playback.meter, stop: { [weak self] in self?.model.stopSpeaking() })
        }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.hideWindow = { [weak self] in self?.window.orderOut(nil) }
        model.startOCR = { [weak self] in self?.captureOCR() }
        model.onWindowChanged = { [weak self] in self?.window.level = self?.model.keepOnTop == true ? .floating : .normal }
        model.onTranslationHeightChanged = { [weak self] contentHeight in
            guard let self, contentHeight > 64 else { return }
            let visible = (self.window.screen ?? NSScreen.main)?.visibleFrame ?? self.window.frame
            let height = min(max(320, ceil(contentHeight)), max(320, min(680, visible.height - 32)))
            guard abs(self.window.frame.height - height) > 1 else { return }
            var frame = self.window.frame
            frame.origin.y = max(visible.minY + 8, frame.maxY - height)
            frame.size.height = height
            self.window.setFrame(frame, display: true)
        }
        window.contentView = wrap(TranslateView(model: model), translationGlass: true)
        model.onShortcutRecording = { [weak self] recording in
            guard let self else { return }
            if recording { self.shortcuts.suspend() }
            else if !self.preview || self.shortcutTest { self.model.hotkeysReady = self.shortcuts.resume() }
        }
        model.onPreferences = { [weak self] in
            guard let self else { return nil }
            let ok = self.shortcuts.install([self.model.translateShortcut, self.model.readShortcut, self.model.ocrShortcut])
            self.model.hotkeysReady = ok
            if !ok, self.shortcuts.installed.count == 3 {
                self.model.translateShortcut = self.shortcuts.installed[0]; self.model.readShortcut = self.shortcuts.installed[1]; self.model.ocrShortcut = self.shortcuts.installed[2]
                self.model.hotkeysReady = true
            }
            if ok { self.updateMenu() }
            return ok ? nil : (self.shortcuts.installed.count == 3 ? "快捷键被其他应用占用，已保留原来的快捷键。" : "快捷键注册失败，请换一个组合键重试。")
        }
        model.onWindowChanged?()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuImage = NSImage(named: "MenuBar") ?? NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: "Sonuvi")
        menuImage?.isTemplate = true; menuImage?.size = NSSize(width: 18, height: 18)
        status.button?.image = menuImage
        updateMenu()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { [weak self] event in
            self?.model.usage.touch()
            if event.type == .leftMouseDown { self?.mouseDown = nil; self?.mouseTask?.cancel() }
            if event.type == .keyDown, event.keyCode == 53, self?.model.recordingShortcut != true, self?.settings?.isKeyWindow != true {
                self?.bubble?.orderOut(nil); self?.window.orderOut(nil); self?.model.cancel(); self?.ocrTask?.cancel(); return nil
            }
            return event
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in guard let self else { return }; self.model.usage.tick(windowActive: self.window.isKeyWindow || self.settings?.isKeyWindow == true) } }
        shortcuts.onTranslate = { [weak self] in guard self?.model.recordingShortcut != true else { return }; self?.translateSelection() }
        shortcuts.onRead = { [weak self] in guard self?.model.recordingShortcut != true else { return }; self?.readSelection() }
        shortcuts.onOCR = { [weak self] in guard self?.model.recordingShortcut != true else { return }; self?.captureOCR() }
        if preview {
            model.previewMode = true
            model.usage.loadPreview()
            if shortcutTest {
                model.shortcutTestMode = true
                let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
                model.translateShortcut = ShortcutSpec.load("translateShortcut", fallback: ShortcutSpec(keyCode: UInt32(kVK_ANSI_T), modifiers: mods, label: "⌃⌥⇧⌘T"))
                model.readShortcut = ShortcutSpec.load("readShortcut", fallback: ShortcutSpec(keyCode: UInt32(kVK_ANSI_R), modifiers: mods, label: "⌃⌥⇧⌘R"))
                model.ocrShortcut = ShortcutSpec.load("ocrShortcut", fallback: ShortcutSpec(keyCode: UInt32(kVK_ANSI_O), modifiers: mods, label: "⌃⌥⇧⌘O"))
                model.hotkeysReady = shortcuts.install([model.translateShortcut, model.readShortcut, model.ocrShortcut])
            }
            model.source = "thoughtful"; model.result = "体贴的；深思熟虑的"
            model.word = WordResult(translation: "体贴的；深思熟虑的", phonetic: "/ˈθɔːtfəl/", definitions: [Definition(pos: "adj.", meaning: "体贴的，关心他人的"), Definition(pos: "adj.", meaning: "经过认真思考的，深思熟虑的")], example: "That was a very thoughtful suggestion.", exampleTranslation: "那是一个考虑得很周到的建议。")
            if let scenario = Bundle.main.object(forInfoDictionaryKey: "MusePreviewScenario") as? String {
                switch scenario {
                case "sentence":
                    model.setSource("Let life be beautiful like summer flowers and death like autumn leaves.")
                    model.result = "让生命如夏花般美丽，让死亡如秋叶般静美。"
                case "reverse":
                    model.setSource("让生命如夏花般美丽，让死亡如秋叶般静美。")
                    model.result = "Let life be beautiful like summer flowers and death like autumn leaves."
                case "loading": model.setSource("Let life be beautiful like summer flowers."); model.busy = true
                case "empty": model.setSource("")
                default: break
                }
            }
            showWindow()
            runNativeDiagnostics()
            return
        }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        model.refreshStatus()
        model.hotkeysReady = shortcuts.install([model.translateShortcut, model.readShortcut, model.ocrShortcut])
        syncPermissionMonitors()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.bubble?.orderOut(nil); self?.mouseTask?.cancel() }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.syncPermissionMonitors() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.didReceiveService else { return }; self.showWindow()
        }
        if !model.runtime.ready && model.runtime.canImport { model.runtime.install(importExisting: true) }
    }
    func syncPermissionMonitors() {
        let granted = SelectionReader.trusted
        model.permissionGranted = granted; model.screenPermission = CGPreflightScreenCaptureAccess()
        if !granted {
            for monitor in [mouseMonitor, downMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            mouseMonitor = nil; downMonitor = nil; bubble?.orderOut(nil)
            return
        }
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in Task { @MainActor in self?.onMouseUp(event) } }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel]) { [weak self] event in Task { @MainActor in
            self?.bubble?.orderOut(nil); self?.mouseTask?.cancel()
            if event.type == .leftMouseDown { self?.mouseDown = NSEvent.mouseLocation }
        } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if !preview { syncPermissionMonitors() }
    }
    func wrap<Content: View>(_ content: Content, translationGlass: Bool = false) -> NSView {
        let hosting = NSHostingView(rootView: content.ignoresSafeArea())
        if #available(macOS 14.0, *) { hosting.safeAreaRegions = [] }
        hosting.autoresizingMask = [.width, .height]
        if translationGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            // The native window clips the outer corners; avoid a second rim.
            glass.cornerRadius = 0
            glass.contentView = hosting
            return glass
        }
        // NSWindow owns the outer silhouette and border. A second rounded glass
        // shell draws a competing rim with a different corner curve.
        let blur = NSVisualEffectView(); blur.material = translationGlass ? .menu : .underWindowBackground; blur.blendingMode = .behindWindow; blur.state = translationGlass ? .active : .followsWindowActiveState
        blur.addSubview(hosting); hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor), hosting.topAnchor.constraint(equalTo: blur.topAnchor), hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor)])
        return blur
    }
    func updateMenu() {
        guard status != nil else { return }
        let menu = NSMenu(); menu.delegate = self; populateMenu(menu); status.menu = menu
        // The native application menu also owns these equivalents while this
        // accessory app is active; the status menu alone is not an edit route.
        if let main = NSApp.mainMenu {
            let actions: NSMenuItem
            if let existing = main.item(withTitle: "操作") { actions = existing }
            else { actions = NSMenuItem(title: "操作", action: nil, keyEquivalent: ""); main.addItem(actions) }
            let submenu = NSMenu(title: "操作")
            for (title, selector, shortcut) in [
                ("翻译选中文字", #selector(translateSelection), model.translateShortcut),
                ("朗读选中英文", #selector(readSelection), model.readShortcut),
                ("截图翻译", #selector(captureOCR), model.ocrShortcut)
            ] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: shortcut.menuKey)
                item.keyEquivalentModifierMask = shortcut.menuModifiers; item.target = self; submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let preferences = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
            preferences.target = self; submenu.addItem(preferences)
            if preview {
                let menuPreview = NSMenuItem(title: "菜单栏预览", action: nil, keyEquivalent: "")
                let previewMenu = NSMenu(); previewMenu.delegate = self; populateMenu(previewMenu)
                menuPreview.submenu = previewMenu; submenu.addItem(menuPreview)
            }
            actions.submenu = submenu
        }
    }
    func menuWillOpen(_ menu: NSMenu) { populateMenu(menu); menuMotion.active = true }
    func menuDidClose(_ menu: NSMenu) { menuMotion.active = false }
    func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems(); menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, symbol: String? = nil, enabled: Bool = true, key: String = "", shortcut: ShortcutSpec? = nil) {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: key); row.target = self; row.isEnabled = enabled
            if let shortcut { row.keyEquivalent = shortcut.menuKey; row.keyEquivalentModifierMask = shortcut.menuModifiers }
            if let symbol { row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(row)
        }
        let summary = NSMenuItem()
        let header = NSHostingView(rootView: MenuSummary(usage: model.usage, motion: menuMotion))
        if #available(macOS 14.0, *) { header.safeAreaRegions = [] }
        header.frame = NSRect(x: 0, y: 0, width: 296, height: ceil(header.fittingSize.height))
        summary.view = header; menu.addItem(summary)
        menu.addItem(.separator())
        item("打开翻译窗口", #selector(showWindow), symbol: "rectangle.on.rectangle")
        item("翻译选中文字", #selector(translateSelection), symbol: "character.bubble", shortcut: model.translateShortcut)
        item("朗读选中英文", #selector(readSelection), symbol: "speaker.wave.2", shortcut: model.readShortcut)
        item(model.ocrBusy ? "取消截图翻译" : "截图翻译", #selector(captureOCR), symbol: "viewfinder", shortcut: model.ocrShortcut)
        item("翻译剪贴板内容", #selector(translateClipboard), symbol: "doc.on.clipboard")
        if model.readingActive { item("停止朗读", #selector(stopReading), symbol: "stop.circle") }
        menu.addItem(.separator())
        item("划词按钮", #selector(toggleLookup), symbol: "cursorarrow.rays"); menu.items.last?.state = model.mouseLookup ? .on : .off
        let appearance = NSMenuItem(title: "外观", action: nil, keyEquivalent: ""); appearance.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let sub = NSMenu()
        for (index, mode) in AppearanceMode.allCases.enumerated() { let row = NSMenuItem(title: mode.rawValue, action: #selector(changeAppearance(_:)), keyEquivalent: ""); row.target = self; row.tag = index; row.state = model.appearance == mode ? .on : .off; sub.addItem(row) }
        appearance.submenu = sub; menu.addItem(appearance)
        item("使用统计…", #selector(showStatistics), symbol: "chart.xyaxis.line")
        item("设置…", #selector(showSettings), symbol: "gearshape", key: ",")
        menu.addItem(.separator()); item("退出 Sonuvi", #selector(quit), key: "q")
    }
    @objc func showStatistics() { model.settingsTab = "统计"; showSettings() }
    @objc func stopReading() { model.stopSpeaking() }
    @objc func toggleLookup() { model.mouseLookup.toggle(); UserDefaults.standard.set(model.mouseLookup, forKey: "mouseLookup"); if !model.mouseLookup { bubble?.orderOut(nil) } }
    @objc func changeAppearance(_ sender: NSMenuItem) { model.appearance = AppearanceMode.allCases[sender.tag]; UserDefaults.standard.set(model.appearance.rawValue, forKey: "appearance") }
    @objc func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { model.error = "剪贴板中没有可翻译的文字。"; showWindow(); return }
        model.setSource(text); showWindow(); model.translate()
    }
    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate(); usageTimer?.invalidate(); model.usage.persist()
        model.cancel(); model.stopSpeaking(); model.runtime.cancel(); captureTask?.cancel(); ocrTask?.cancel(); mouseTask?.cancel()
        for monitor in [localMonitor, mouseMonitor, downMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        if let observer = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func runNativeDiagnostics() {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "MuseDiagnosticsOutput") as? String else { return }
        let runtimeRoot = Bundle.main.object(forInfoDictionaryKey: "MuseDiagnosticsRuntime") as? String
        Task.detached {
            var report: [String: Any] = [:]
            do { let output = try recognizeOCRFixture(); report["ocr"] = ["passed": true, "text": output] }
            catch { let e = error as NSError; report["ocr"] = ["passed": false, "error": "\(e.domain) \(e.code)", "detail": error.localizedDescription] }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            if let runtimeRoot,
               let bridge = Bundle.main.url(forResource: "kokoro_bridge", withExtension: "py"),
               let service = Bundle.main.url(forResource: "kokoro_service", withExtension: "py") {
                func info() -> RuntimeInfo? {
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: runtimeRoot).appendingPathComponent("ready.json")) else { return nil }
                    return try? JSONDecoder().decode(RuntimeInfo.self, from: data)
                }
                func run(_ args: [String], inputText: String? = nil) -> [String: Any] {
                    guard let current = info() else { return ["passed": false, "error": "Missing runtime"] }
                    let process = Process(); process.executableURL = URL(fileURLWithPath: current.python); process.arguments = args
                    let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        if let inputText { try input.fileHandleForWriting.write(contentsOf: Data(inputText.utf8)) }
                        try input.fileHandleForWriting.close()
                        let reply = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                        return ["passed": process.terminationStatus == 0, "reply": String(data: reply, encoding: .utf8) ?? ""]
                    } catch { return ["passed": false, "error": error.localizedDescription] }
                }
                let args = [bridge.path, "--root", runtimeRoot, "--service", service.path]
                if Bundle.main.object(forInfoDictionaryKey: "MuseDiagnosticsReimport") as? Bool == true {
                    report["serviceShutdown"] = run(args + ["--shutdown"])
                    report["ttsBeforeReimport"] = run(args, inputText: "{\"text\":\"Hello David. This is the local voice before importing.\",\"voice\":\"af_heart\"}")
                    if let setup = Bundle.main.url(forResource: "runtime_setup", withExtension: "py"), let uv = Bundle.main.url(forResource: "uv", withExtension: nil) {
                        report["runtimeReimport"] = run([setup.path, "--root", runtimeRoot, "--mode", "import", "--uv", uv.path])
                    }
                }
                report["independentTTS"] = run(args, inputText: "{\"text\":\"Hello David. This is the independent local voice.\",\"voice\":\"af_heart\"}")
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showWindow() { presentWindow(near: nil) }
    func presentWindow(near point: NSPoint?) {
        bubble?.orderOut(nil)
        if let point, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            var size = window.frame.size; size.width = min(size.width, screen.visibleFrame.width - 16); size.height = min(size.height, screen.visibleFrame.height - 16)
            window.setFrame(NSRect(origin: WindowGeometry.origin(near: point, size: size, visible: screen.visibleFrame), size: size), display: true)
        } else if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc func showSettings() {
        if settings == nil {
            // A native unified toolbar provides room for the inset controls;
            // the full-size sidebar continues underneath its transparent chrome.
            let win = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 948, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            win.title = "Sonuvi 设置"; win.titleVisibility = .hidden; win.titlebarAppearsTransparent = true; win.backgroundColor = .windowBackgroundColor; win.isOpaque = true
            let toolbar = NSToolbar(identifier: "SonuviSettingsChrome")
            toolbar.allowsUserCustomization = false; toolbar.displayMode = .iconOnly
            win.toolbar = toolbar; win.toolbarStyle = .unified; win.titlebarSeparatorStyle = .none
            win.isReleasedWhenClosed = false; win.minSize = NSSize(width: 740, height: 560); win.contentView = wrap(SettingsView(model: model))
            settings = win
        }
        settings?.center(); NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    @objc func translateSelection() { capture(read: false) }
    @objc func readSelection() { dismissSelectionBubble(); if model.readingActive { model.stopSpeaking(); return }; capture(read: true) }
    func capture(read: Bool) {
        dismissSelectionBubble()
        let previous = captureTask; previous?.cancel(); captureID = UUID(); let id = captureID; let point = SelectionReader.selectionAnchor() ?? NSEvent.mouseLocation
        let originApplication = NSWorkspace.shared.frontmostApplication
        let origin = originApplication?.bundleIdentifier
        // Never read the Settings field editor (which may contain an API key).
        // A shortcut used inside the translation window operates on its text.
        let localText: String? = NSApp.isActive && window.isKeyWindow ? selectedTranslationText() : nil
        let sourceApp = localText == nil ? origin : model.sourceApp
        model.cancel()
        captureTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard !Task.isCancelled, self.captureID == id else { return }
            guard localText != nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == originApplication?.processIdentifier else { return }
            if localText == nil && !SelectionReader.trusted {
                self.model.setSource("")
                self.model.showIssue("尚未获得取词权限。可先粘贴文字使用，或前往设置开启辅助功能。", settingsTab: "通用")
                if read { self.model.readingPresentation = localText == nil ? .floating : .inline; self.readingBar.anchor = point; self.model.readingStatus = self.model.error }
                else { self.presentWindow(near: point) }; return
            }
            let captured: String?
            if let localText { captured = localText }
            else { captured = await SelectionReader.capture(allowClipboard: self.model.clipboardFallback) }
            guard let text = captured, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                guard !Task.isCancelled, self.captureID == id else { return }
                self.model.setSource(""); self.model.error = "未获取到选中文字。可使用截图翻译，或复制后粘贴。"
                if read { self.model.readingPresentation = localText == nil ? .floating : .inline; self.readingBar.anchor = point; self.model.readingStatus = self.model.error }
                else { self.showWindow() }; return
            }
            guard !Task.isCancelled, self.captureID == id else { return }
            self.model.setSource(text, app: sourceApp)
            if read {
                self.bubble?.orderOut(nil); self.readingBar.anchor = point
                if TextRules.direction(text) == .toChinese { self.model.speak(text, presentation: localText == nil ? .floating : .inline) }
                else { self.model.translate(readAfter: true, presentation: localText == nil ? .floating : .inline) }
            } else {
                self.presentWindow(near: localText == nil ? point : nil); self.model.translate()
            }
        }
    }
    func selectedTranslationText() -> String {
        if let editor = window.firstResponder as? NSTextView {
            let range = editor.selectedRange()
            let text = editor.string as NSString
            if range.length > 0, NSMaxRange(range) <= text.length { return text.substring(with: range) }
        }
        return model.source
    }
    @objc func captureOCR() {
        if model.ocrBusy { ocrTask?.cancel(); return }
        guard CGPreflightScreenCaptureAccess() else {
            model.screenPermission = false
            model.showIssue("截图翻译需要屏幕录制权限，请在通用设置中开启。", settingsTab: "通用")
            showWindow(); return
        }
        let origin = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        captureTask?.cancel(); model.cancel(); bubble?.orderOut(nil); window.orderOut(nil); settings?.orderOut(nil)
        model.ocrBusy = true
        ocrTask = Task { [weak self] in
            guard let self else { return }
            defer { self.model.ocrBusy = false }
            do {
                if let text = try await OCRService.capture() { try Task.checkCancellation(); self.model.setSource(text, app: origin); self.presentWindow(near: NSEvent.mouseLocation); self.model.translate() }
            } catch is CancellationError { }
            catch { self.model.error = error.localizedDescription; self.showWindow() }
        }
    }
    func useSelection(_ text: String, app: String? = nil, readAfter: Bool = false) {
        dismissSelectionBubble(); captureTask?.cancel(); model.setSource(text, app: app); presentWindow(near: NSEvent.mouseLocation); model.translate()
    }
    func onMouseUp(_ event: NSEvent) {
        defer { mouseDown = nil }
        guard model.mouseLookup, Date() >= lookupSuppressedUntil,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !model.excludedApps.contains(app.bundleIdentifier ?? "") else { return }
        let point = NSEvent.mouseLocation
        guard !(bubble?.isVisible == true && bubble?.frame.contains(point) == true),
              !(window.isVisible && window.frame.contains(point)) else { return }
        // A stale/double mouse-up must never resurrect a consumed selection.
        // Every lookup needs a fresh external mouse-down, cleared by bubble actions.
        guard let start = mouseDown else { return }
        let dragged = hypot(point.x - start.x, point.y - start.y) > 3
        guard dragged || event.clickCount >= 2 else { return }
        mouseTask?.cancel()
        let pid = app.processIdentifier
        mouseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled, Date() >= self.lookupSuppressedUntil, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let text = SelectionReader.fromAccessibility(), !text.isEmpty, text.count <= 6000 else { return }
            self.showBubble(text: text, point: point, app: app.bundleIdentifier)
        }
    }
    @objc func translateService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receiveService(pasteboard, read: false, error: error)
    }
    @objc func readService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receiveService(pasteboard, read: true, error: error)
    }
    func receiveService(_ pasteboard: NSPasteboard, read: Bool, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "请先选中文字。"; return
        }
        guard text.count <= 6000 else { error.pointee = "单次最多支持 6000 个字符。"; return }
        didReceiveService = true; dismissSelectionBubble(); captureTask?.cancel()
        // A service pasteboard does not identify its sender. The foreground app
        // can change while Services dispatches, so do not misattribute usage.
        let point = NSEvent.mouseLocation
        model.setSource(text)
        if read {
            readingBar.anchor = point
            if model.direction == .toChinese { model.speak(text, presentation: .floating) }
            else { model.translate(readAfter: true, presentation: .floating) }
        } else { presentWindow(near: point); model.translate() }
    }
    func dismissSelectionBubble() {
        mouseTask?.cancel(); mouseTask = nil; mouseDown = nil
        lookupSuppressedUntil = Date().addingTimeInterval(0.5)
        bubble?.orderOut(nil)
    }
    func showBubble(text: String, point: NSPoint, app: String?) {
        if bubble == nil {
            bubble = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: 86, height: 42), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            bubble?.isOpaque = false; bubble?.backgroundColor = .clear; bubble?.hasShadow = true
            bubble?.level = .floating; bubble?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        bubble?.contentView = NSHostingView(rootView: SelectionBubble(translate: { [weak self] in self?.useSelection(text, app: app) }, read: { [weak self] in
            guard let self else { return }; self.dismissSelectionBubble()
            self.captureTask?.cancel(); self.model.setSource(text, app: app); self.readingBar.anchor = point
            if TextRules.direction(text) == .toEnglish { self.model.translate(readAfter: true, presentation: .floating) }
            else { self.model.speak(text, presentation: .floating) }
        }))
        let frame = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame ?? NSScreen.main!.visibleFrame
        bubble?.setFrameOrigin(WindowGeometry.origin(near: point, size: NSSize(width: 86, height: 42), visible: frame)); bubble?.orderFrontRegardless()
    }
}

if CommandLine.arguments.contains("--self-test") { runSelfTests() }
else if CommandLine.arguments.contains("--editor-test") { MainActor.assumeIsolated { runEditorTests() } }
else if CommandLine.arguments.contains("--ocr-test") { runOCRTest() }
else if CommandLine.arguments.contains("--network-test") { Task { await runNetworkTests(); exit(0) }; dispatchMain() }
else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared; let delegate = AppDelegate(); application.delegate = delegate; application.run()
    }
}
