// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI
import Carbon
import OSLog

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
    var onboardingWindow: NSWindow?
    var welcomeTip: NSPopover?
    var onboardingCompletedAt: Date?
    var onboarding: OnboardingState = {
        if Bundle.main.object(forInfoDictionaryKey: "SonuviOnboardingPreview") as? Bool == true {
            return OnboardingState(defaults: UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "Sonuvi") + ".onboarding")!)
        }
        return OnboardingState()
    }()
    var needsOnboarding: Bool { !onboarding.completed || onboarding.replaying || onboarding.awaitingPermissionReturn }
    var onboardingVisible: Bool { onboardingWindow?.isVisible == true }
    var bubble: BubblePanel?
    let readingBar = ReadingBarController()
    let browserServer = BrowserMessageServer()
    let menuMotion = MenuMotion()
    var mouseMonitor: Any?
    var localMonitor: Any?
    var workspaceObserver: Any?
    var selectionRecoveryObservers: [Any] = []
    let selectionLog = Logger(subsystem: "com.wusir.musetranslate", category: "Selection")
    let permissionReturn = PermissionReturnState()
    let accessibilityRepair = AccessibilityRepairState()
    let installationPermissions = InstallationPermissionState()
    let relaunch = RelaunchCoordinator()
    var permissionAction: Task<Void, Never>?
    var leftForPermission = false
    var permissionRequestInProgress = false
    var restartInProgress = false
    var startupPresentation = StartupPresentationGate()
    var permissionTimer: Timer?
    var usageTimer: Timer?
    var mouseTask: Task<Void, Never>?
    var captureTask: Task<Void, Never>?
    var captureID = UUID()
    var selectionLookup = SelectionLookupState()
    var keyboardSelection: (code: UInt16, pid: pid_t, action: KeyboardSelectionAction)?
    var lastSelection: (pid: pid_t, text: String)?
    var didReceiveService = false
    var ocrTask: Task<Void, Never>?
    var ocrID = UUID()
    let preview = CommandLine.arguments.contains("--preview") || (Bundle.main.object(forInfoDictionaryKey: "MusePreview") as? Bool == true)
    let shortcutTest = Bundle.main.object(forInfoDictionaryKey: "MuseShortcutTest") as? Bool == true

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !preview, let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.wusir.musetranslate").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(options: [.activateIgnoringOtherApps]); NSApp.terminate(nil); return
        }
        // Older Settings restarts incorrectly wrote the onboarding-only flag.
        if !preview && onboarding.completed && permissionReturn.destination == nil {
            UserDefaults.standard.set(false, forKey: "onboarding.permissionReturn")
        }
        NSApp.setActivationPolicy(.accessory)
        model.applyAppearance()
        model.onLanguageChanged = { [weak self] in
            self?.updateMenu()
            self?.settings?.title = L10n.text("Sonuvi 设置")
            self?.onboardingWindow?.title = L10n.text("欢迎使用 Sonuvi")
        }
        let appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.tag = 701; appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: L10n.text("退出 Sonuvi"), action: #selector(quit), keyEquivalent: "q")
        appMenu.addItem(appItem)
        let edit = NSMenuItem(); edit.tag = 702; edit.title = L10n.text("编辑"); edit.submenu = NSMenu(title: L10n.text("编辑"))
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.submenu?.addItem(withTitle: L10n.text(title), action: action, keyEquivalent: key) }
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
        model.requestPermission = { [weak self] screen in self?.requestPermission(screen: screen) }
        model.repairPermissions = { [weak self] in self?.repairPermissions() }
        model.restartApplication = { [weak self] in self?.restartApplication() }
        model.restartOnboarding = { [weak self] in
            guard let self, !self.permissionRequestInProgress, !self.restartInProgress else { return }
            self.onboarding.restart(); self.showOnboarding()
        }
        model.hideWindow = { [weak self] in self?.cancelOCR(); self?.window.orderOut(nil) }
        model.cancelOCR = { [weak self] in self?.cancelOCR() }
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
        model.onLocalSelection = { [weak self] point, clicks, shift in
            self?.finishLocalSelection(at: point, clicks: clicks, shift: shift)
        }
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
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .scrollWheel]) { [weak self] event in
            self?.model.usage.touch()
            if event.type == .leftMouseDown {
                self?.mouseTask?.cancel(); self?.selectionLookup.invalidate()
                // Keep the bubble alive until its button receives mouse-up.
                if let self, event.window !== self.bubble {
                    self.dismissSelectionBubble()
                    if event.window === self.window {
                        self.selectionLookup.begin(at: self.window.convertPoint(toScreen: event.locationInWindow))
                    }
                }
            }
            if event.window === self?.window {
                if event.type == .keyDown { self?.onSelectionKeyDown(event, local: true) }
                if event.type == .keyUp { self?.onSelectionKeyUp(event, local: true) }
            }
            if event.type == .leftMouseUp { self?.onLocalMouseUp(event) }
            if event.type == .scrollWheel { self?.dismissSelectionBubble() }
            if event.type == .keyDown, event.keyCode == 53, self?.model.recordingShortcut != true, self?.settings?.isKeyWindow != true, self?.onboardingWindow?.isKeyWindow != true {
                self?.dismissSelectionBubble(); self?.window.orderOut(nil); self?.model.cancel(); self?.cancelOCR(); return nil
            }
            return event
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in guard let self else { return }; self.model.usage.tick(windowActive: self.window.isKeyWindow || self.settings?.isKeyWindow == true) } }
        shortcuts.onTranslate = { [weak self] in guard self?.model.recordingShortcut != true else { return }; self?.translateSelection() }
        shortcuts.onRead = { [weak self] in guard self?.model.recordingShortcut != true else { return }; self?.readSelection() }
        shortcuts.onOCR = { [weak self] in guard self?.model.recordingShortcut != true else { return }; self?.captureOCR() }
        if preview {
            startupPresentation.finishPreparation()
            model.previewMode = true
            model.usage.loadPreview()
            if Bundle.main.object(forInfoDictionaryKey: "MuseDiagnosticsRuntime") != nil { model.runtime.prepareBundledIfNeeded() }
            if Bundle.main.object(forInfoDictionaryKey: "SonuviOnboardingPreview") as? Bool == true {
                model.hotkeysReady = true
                if Bundle.main.object(forInfoDictionaryKey: "SonuviPreviewPermissionsReady") as? Bool == true { model.permissionGranted = true; model.screenPermission = true }
                if Bundle.main.object(forInfoDictionaryKey: "SonuviPreviewTranslationReady") as? Bool == true { model.hasKey = true }
                if let start = Bundle.main.object(forInfoDictionaryKey: "SonuviOnboardingStep") as? Int,
                   let step = OnboardingStep(rawValue: start), !onboarding.awaitingPermissionReturn { onboarding.go(step) }
                showOnboarding(); return
            }
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
        if InstallationPermissionState.isInstalled(Bundle.main.bundleURL.path) {
            browserServer.receive = { [weak self] request in
                guard let self else { return BrowserReply(ok: false, error: L10n.text("请先打开 Sonuvi，再重试。")) }
                guard self.model.browser.enabled, let token = self.model.browser.connectionToken, request.token == token else {
                    return BrowserReply(ok: false, error: L10n.text("请先在 Sonuvi 设置中启用浏览器连接。"))
                }
                if request.action == .ping { return BrowserReply(ok: true, error: nil) }
                guard self.startupPresentation.canPresent else { return BrowserReply(ok: false, error: L10n.text("Sonuvi 正在启动，请稍后重试。")) }
                guard !self.needsOnboarding, !self.onboardingVisible else {
                    self.showOnboarding()
                    return BrowserReply(ok: false, error: L10n.text("请先完成 Sonuvi 的首次设置。"))
                }
                guard let text = request.text else { return BrowserReply(ok: false, error: L10n.text("请先选中文字。")) }
                self.dismissSelectionBubble(); self.captureTask?.cancel(); self.model.setSource(text)
                if request.action == .read {
                    self.readingBar.anchor = NSEvent.mouseLocation
                    if self.model.direction == .toChinese { self.model.speak(text, presentation: .floating) }
                    else { self.model.translate(readAfter: true, presentation: .floating) }
                } else { self.presentWindow(near: NSEvent.mouseLocation); self.model.translate() }
                return BrowserReply(ok: true, error: nil)
            }
            browserServer.start()
        }
        model.runtime.startBackgroundWarmup { [weak self] in self?.model.voice ?? "af_heart" }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        model.refreshStatus()
        model.hotkeysReady = shortcuts.install([model.translateShortcut, model.readShortcut, model.ocrShortcut])
        syncPermissionMonitors()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                let before = self.selectionLookup.generation
                self.selectionLookup.activated(pid: pid)
                if let pid, self.allowsSelectionLookup(pid: pid) { SelectionReader.prepareAccessibility(pid: pid) }
                if before != self.selectionLookup.generation {
                    self.dismissSelectionBubble()
                }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            selectionRecoveryObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncPermissionMonitors(reinstall: true) }
            })
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.syncPermissionMonitors() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let resuming = self.accessibilityRepair.consume()
            let defaults = UserDefaults.standard
            let returning = self.onboarding.completed || defaults.bool(forKey: "accessibilityPermissionRequested") || defaults.bool(forKey: "screenPermissionRequested")
            let repair = self.installationPermissions.shouldRepair(
                fingerprint: InstallationPermissionState.fingerprint(),
                installed: InstallationPermissionState.isInstalled(Bundle.main.bundlePath),
                returningUser: returning, accessibility: self.model.permissionGranted,
                screen: self.model.screenPermission, resumingRepair: resuming)
            if !repair { self.startupPresentation.finishPreparation() }
            if resuming {
                self.model.permissionMessage = defaults.string(forKey: "permissions.repair.notice") ?? "旧权限记录已清理，请重新开启辅助功能和屏幕录制。"
                defaults.removeObject(forKey: "permissions.repair.notice")
                if !self.restorePermissionWindow() { self.showDefaultWindow() }
            } else if repair {
                if self.onboarding.completed {
                    defaults.set(false, forKey: "onboarding.permissionReturn")
                    self.onboardingWindow?.orderOut(nil)
                }
                self.model.settingsTab = "权限"
                self.repairPermissions(beforeInitialPresentation: true)
            } else if !self.didReceiveService {
                if !self.restorePermissionWindow() { self.showDefaultWindow() }
            }
        }
        if model.runtime.bundledRuntime != nil { model.runtime.prepareBundledIfNeeded() }
        else { model.runtime.checkForModelUpdates(quiet: true) }
    }
    func syncPermissionMonitors(reinstall: Bool = false, preserveGesture: Bool = false) {
        let granted = SelectionReader.trusted
        let changed = model.permissionGranted != granted
        model.permissionGranted = granted; model.screenPermission = CGPreflightScreenCaptureAccess()
        if changed { selectionLog.info("Accessibility permission changed: \(granted)") }
        if !granted || reinstall {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            if !granted || !preserveGesture { dismissSelectionBubble() }
        }
        guard granted, mouseMonitor == nil else { return }
        // AppKit invokes this on the main thread. Keep down/up handling ordered
        // and capture the event's position, not a later live cursor position.
        // Global monitors already exclude events delivered to Sonuvi itself.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel, .keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event.type {
                case .leftMouseDown:
                    self.dismissSelectionBubble()
                    self.selectionLookup.begin(at: event.locationInWindow)
                case .leftMouseUp: self.onMouseUp(event)
                case .keyDown: self.onSelectionKeyDown(event)
                case .keyUp: self.onSelectionKeyUp(event)
                default: self.dismissSelectionBubble()
                }
            }
        }
        if mouseMonitor == nil { selectionLog.error("Could not install selection event monitor; will retry") }
        else { selectionLog.info("Selection event monitor installed") }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard startupPresentation.canPresent && !restartInProgress else { return false }
        // Re-activation should preserve Settings/onboarding rather than create
        // a translation window over the window the user is already using.
        let candidates: [NSWindow?] = [onboardingWindow, settings, window]
        if flag, let existing = candidates.compactMap({ $0 }).first(where: { $0.isVisible }) {
            existing.makeKeyAndOrderFront(nil); return false
        }
        if let completed = onboardingCompletedAt,
           Date().timeIntervalSince(completed) < 5 {
            recordOnboardingDiagnostic("reopen-suppressed"); return false
        }
        recordOnboardingDiagnostic("reopen")
        welcomeTip?.performClose(nil)
        showDefaultWindow(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidResignActive(_ notification: Notification) {
        if permissionReturn.destination != nil { leftForPermission = true }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if !preview { syncPermissionMonitors(reinstall: true, preserveGesture: true) }
        if leftForPermission && !permissionRequestInProgress && !restartInProgress {
            _ = restorePermissionWindow()
        }
    }
    @discardableResult
    func restorePermissionWindow() -> Bool {
        guard startupPresentation.canPresent && !restartInProgress,
              let destination = permissionReturn.destination else { return false }
        let tab = permissionReturn.settingsTab
        permissionReturn.clear(); leftForPermission = false
        relaunch.cancel()
        switch destination {
        case .onboarding: showOnboarding()
        case .settings:
            // Migrate the erroneous flag written by older Settings restarts.
            if onboarding.completed { UserDefaults.standard.set(false, forKey: "onboarding.permissionReturn") }
            model.settingsTab = tab == "通用" ? "权限" : tab; showSettings()
        }
        return true
    }
    func rememberPermissionWindow() {
        let destination: PermissionDestination = (onboardingVisible || !onboarding.completed) ? .onboarding : .settings
        permissionReturn.prepare(destination, settingsTab: model.settingsTab)
        if destination == .onboarding { onboarding.preparePermissionReturn() }
    }
    func permissionIssue(_ text: String) {
        model.permissionMessage = text
        if onboardingVisible { onboarding.error = text }
    }
    func wrap<Content: View>(_ content: Content, translationGlass: Bool = false) -> NSView {
        let hosting = NSHostingView(rootView: LocalizedRoot(content: content).ignoresSafeArea())
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
            if let existing = main.items.first(where: { $0.tag == 703 }) { actions = existing }
            else { actions = NSMenuItem(title: L10n.text("操作"), action: nil, keyEquivalent: ""); actions.tag = 703; main.addItem(actions) }
            actions.title = L10n.text("操作")
            main.items.first(where: { $0.tag == 701 })?.submenu?.items.first?.title = L10n.text("退出 Sonuvi")
            if let edit = main.items.first(where: { $0.tag == 702 }) {
                edit.title = L10n.text("编辑"); edit.submenu?.title = L10n.text("编辑")
                for (item, title) in zip(edit.submenu?.items ?? [], ["撤销", "剪切", "复制", "粘贴", "全选"]) { item.title = L10n.text(title) }
            }
            let submenu = NSMenu(title: L10n.text("操作"))
            for (title, selector, shortcut) in [
                ("翻译选中文字", #selector(translateSelection), model.translateShortcut),
                ("朗读选中英文", #selector(readSelection), model.readShortcut),
                ("截图翻译", #selector(captureOCR), model.ocrShortcut)
            ] {
                let item = NSMenuItem(title: L10n.text(title), action: selector, keyEquivalent: shortcut.menuKey)
                item.keyEquivalentModifierMask = shortcut.menuModifiers; item.target = self; submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let preferences = NSMenuItem(title: L10n.text("设置…"), action: #selector(showSettings), keyEquivalent: ",")
            preferences.target = self; submenu.addItem(preferences)
            if preview {
                let menuPreview = NSMenuItem(title: L10n.text("菜单栏预览"), action: nil, keyEquivalent: "")
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
            let row = NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: key); row.target = self; row.isEnabled = enabled
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
        if needsOnboarding { item("继续设置 Sonuvi…", #selector(showOnboarding), symbol: "sparkles") }
        item("打开翻译窗口", #selector(showWindow), symbol: "rectangle.on.rectangle")
        item("翻译选中文字", #selector(translateSelection), symbol: "character.bubble", shortcut: model.translateShortcut)
        item("朗读选中英文", #selector(readSelection), symbol: "speaker.wave.2", shortcut: model.readShortcut)
        item(model.ocrBusy ? "取消截图翻译" : "截图翻译", #selector(captureOCR), symbol: "viewfinder", shortcut: model.ocrShortcut)
        item("翻译剪贴板内容", #selector(translateClipboard), symbol: "doc.on.clipboard")
        if model.readingActive { item("停止朗读", #selector(stopReading), symbol: "stop.circle") }
        menu.addItem(.separator())
        item("划词按钮", #selector(toggleLookup), symbol: "cursorarrow.rays"); menu.items.last?.state = model.mouseLookup ? .on : .off
        let appearance = NSMenuItem(title: L10n.text("外观"), action: nil, keyEquivalent: ""); appearance.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let sub = NSMenu()
        for (index, mode) in AppearanceMode.allCases.enumerated() { let row = NSMenuItem(title: L10n.text(mode.rawValue), action: #selector(changeAppearance(_:)), keyEquivalent: ""); row.target = self; row.tag = index; row.state = model.appearance == mode ? .on : .off; sub.addItem(row) }
        appearance.submenu = sub; menu.addItem(appearance)
        item("使用统计…", #selector(showStatistics), symbol: "chart.xyaxis.line")
        item("设置…", #selector(showSettings), symbol: "gearshape", key: ",")
        menu.addItem(.separator()); item("退出 Sonuvi", #selector(quit), key: "q")
    }
    @objc func showStatistics() { model.settingsTab = "统计"; showSettings() }
    @objc func stopReading() { model.stopSpeaking() }
    @objc func toggleLookup() { model.mouseLookup.toggle(); UserDefaults.standard.set(model.mouseLookup, forKey: "mouseLookup"); if !model.mouseLookup { dismissSelectionBubble() }; syncPermissionMonitors(reinstall: true) }
    @objc func changeAppearance(_ sender: NSMenuItem) { model.appearance = AppearanceMode.allCases[sender.tag]; UserDefaults.standard.set(model.appearance.rawValue, forKey: "appearance") }
    @objc func translateClipboard() {
        if needsOnboarding || onboardingVisible { showOnboarding(); return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { model.error = "剪贴板中没有可翻译的文字。"; showWindow(); return }
        model.setSource(text); showWindow(); model.translate()
    }
    func applicationWillTerminate(_ notification: Notification) {
        browserServer.stop()
        permissionTimer?.invalidate(); usageTimer?.invalidate(); model.usage.persist()
        model.cancel(); model.stopSpeaking(); model.runtime.cancel(); model.runtime.stopBackgroundWarmup(); captureTask?.cancel(); ocrTask?.cancel(); mouseTask?.cancel()
        for monitor in [localMonitor, mouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        if let observer = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in selectionRecoveryObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
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
                if Bundle.main.object(forInfoDictionaryKey: "MuseDiagnosticsWaitForRuntime") as? Bool == true {
                    for _ in 0..<100 {
                        if FileManager.default.fileExists(atPath: runtimeRoot + "/ready.json") { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
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
    @objc func quit() { relaunch.cancel(); permissionReturn.clear(); accessibilityRepair.clear(); NSApp.terminate(nil) }
    @objc func showWindow() {
        if needsOnboarding || onboardingVisible { showOnboarding(); return }
        presentWindow(near: nil)
    }
    func presentWindow(near point: NSPoint?) {
        guard !restartInProgress else { return }
        if needsOnboarding || onboardingVisible { showOnboarding(); return }
        bubble?.orderOut(nil)
        if let point, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            var size = window.frame.size; size.width = min(size.width, screen.visibleFrame.width - 16); size.height = min(size.height, screen.visibleFrame.height - 16)
            window.setFrame(NSRect(origin: WindowGeometry.origin(near: point, size: size, visible: screen.visibleFrame), size: size), display: true)
        } else if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func showDefaultWindow() {
        guard startupPresentation.canPresent && !restartInProgress else { return }
        switch StartupDestination.resolve(onboardingComplete: onboarding.completed && !onboarding.replaying, accessibility: model.permissionGranted, screen: model.screenPermission, keyAccessNeedsAttention: model.keyAccessRequired || !model.keyAccessIssue.isEmpty) {
        case .onboarding: showOnboarding()
        case .permissions: model.settingsTab = "权限"; showSettings()
        case .models: model.settingsTab = "模型"; showSettings()
        case .settings: showSettings()
        }
    }
    @objc func showSettings() {
        guard startupPresentation.canPresent && !restartInProgress else { return }
        if needsOnboarding || onboardingVisible { showOnboarding(); return }
        if settings == nil {
            // A native unified toolbar provides room for the inset controls;
            // the full-size sidebar continues underneath its transparent chrome.
            let win = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 948, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            win.title = L10n.text("Sonuvi 设置"); win.titleVisibility = .hidden; win.titlebarAppearsTransparent = true; win.backgroundColor = .windowBackgroundColor; win.isOpaque = true
            let toolbar = NSToolbar(identifier: "SonuviSettingsChrome")
            toolbar.allowsUserCustomization = false; toolbar.displayMode = .iconOnly
            win.toolbar = toolbar; win.toolbarStyle = .unified; win.titlebarSeparatorStyle = .none
            win.isReleasedWhenClosed = false; win.hidesOnDeactivate = false; win.minSize = NSSize(width: 740, height: 560); win.contentView = wrap(SettingsView(model: model))
            settings = win
        }
        if settings?.isVisible != true { settings?.center() }; NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    @objc func showOnboarding() {
        guard startupPresentation.canPresent && !restartInProgress else { return }
        if onboardingWindow == nil {
            let win = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            win.title = L10n.text("欢迎使用 Sonuvi"); win.titleVisibility = .hidden; win.titlebarAppearsTransparent = true
            win.isReleasedWhenClosed = false; win.hidesOnDeactivate = false; win.isMovableByWindowBackground = true
            win.minSize = NSSize(width: 900, height: 600); win.backgroundColor = .windowBackgroundColor
            let toolbar = NSToolbar(identifier: "SonuviOnboardingChrome"); toolbar.displayMode = .iconOnly
            win.toolbar = toolbar; win.toolbarStyle = .unified; win.titlebarSeparatorStyle = .none
            win.contentView = wrap(OnboardingView(model: model, state: onboarding, requestPermission: { [weak self] in self?.requestPermission(screen: $0) }, restart: { [weak self] in self?.restartApplication() }, complete: { [weak self] in
                guard let self else { return }
                self.onboardingCompletedAt = Date()
                self.onboardingWindow?.orderOut(nil); self.updateMenu(); self.showMenuBarTip()
            }, dismiss: { [weak self] in
                guard let self else { return }
                self.model.stopSpeaking(); self.onboardingWindow?.orderOut(nil); self.showSettings()
            }))
            win.center(); onboardingWindow = win
        }
        window.orderOut(nil); settings?.orderOut(nil); bubble?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true); onboardingWindow?.makeKeyAndOrderFront(nil)
    }
    func recordOnboardingDiagnostic(_ event: String) {
        guard preview, let path = Bundle.main.object(forInfoDictionaryKey: "SonuviOnboardingTrace") as? String else { return }
        let row: [String: Any] = ["event": event, "translationVisible": window.isVisible,
            "onboardingVisible": onboardingVisible, "tipVisible": welcomeTip?.isShown == true]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (previous + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func showMenuBarTip() {
        window.orderOut(nil); settings?.orderOut(nil); bubble?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let button = self.status.button, button.window != nil else { return }
            let popover = NSPopover()
            popover.behavior = .transient; popover.animates = true
            let controller = NSHostingController(rootView: MenuBarWelcomeTip(close: { [weak self] in self?.welcomeTip?.performClose(nil) }))
            popover.contentViewController = controller
            // The localized content owns its height; never reserve a blank footer.
            popover.contentSize = controller.view.fittingSize
            self.welcomeTip = popover
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.recordOnboardingDiagnostic("welcome-tip-shown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak popover] in
                guard let self, let popover, self.welcomeTip === popover else { return }
                popover.performClose(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.recordOnboardingDiagnostic("welcome-tip-settled") }
        }
    }
    func requestPermission(screen: Bool) {
        guard startupPresentation.canPresent, !permissionRequestInProgress && !restartInProgress else { return }
        if preview {
            if Bundle.main.object(forInfoDictionaryKey: "SonuviOnboardingPreview") as? Bool == true {
                if screen { model.screenPermission = true } else { model.permissionGranted = true }
            }
            return
        }
        guard !(screen ? CGPreflightScreenCaptureAccess() : SelectionReader.trusted) else {
            syncPermissionMonitors(); return
        }
        rememberPermissionWindow()
        onboardingWindow?.hidesOnDeactivate = false; settings?.hidesOnDeactivate = false
        model.permissionMessage = ""; permissionRequestInProgress = true
        permissionAction = Task { [weak self] in
            guard let self else { return }
            // Arm before macOS can offer Quit & Reopen, including requests
            // initiated from Settings rather than onboarding.
            do { try await self.relaunch.arm(watchingPermission: true) }
            catch { self.permissionIssue(error.localizedDescription) }
            if screen {
                let requested = UserDefaults.standard.bool(forKey: "screenPermissionRequested")
                UserDefaults.standard.set(true, forKey: "screenPermissionRequested"); UserDefaults.standard.synchronize()
                if !requested { _ = CGRequestScreenCaptureAccess() }
                if !CGPreflightScreenCaptureAccess() {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            } else { SelectionReader.openPermissionSettings() }
            self.permissionRequestInProgress = false
            self.syncPermissionMonitors()
            if NSApp.isActive && self.leftForPermission && (screen ? CGPreflightScreenCaptureAccess() : SelectionReader.trusted) {
                _ = self.restorePermissionWindow()
            }
        }
    }
    func repairPermissions(beforeInitialPresentation: Bool = false) {
        guard startupPresentation.canPresent || beforeInitialPresentation else { return }
        guard !preview && !permissionRequestInProgress && !restartInProgress else { return }
        if !onboardingVisible { model.settingsTab = "权限" }
        rememberPermissionWindow()
        model.permissionRepairing = true; model.permissionMessage = "正在清理旧权限记录，完成后将自动返回此页。"
        permissionRequestInProgress = true
        permissionAction = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try AccessibilityRepair.arguments(bundleID: Bundle.main.bundleIdentifier)
                // Arm first so a successful reset never strands the user in a
                // process with cached access or without an automatic relaunch.
                try await self.relaunch.arm(watchingPermission: false)
                let report = try await AccessibilityRepair.resetBoth(bundleID: Bundle.main.bundleIdentifier)
                let defaults = UserDefaults.standard
                for service in report.cleared {
                    defaults.removeObject(forKey: service == .accessibility ? "accessibilityPermissionRequested" : "screenPermissionRequested")
                }
                guard !report.cleared.isEmpty else {
                    self.relaunch.cancel(); self.permissionRequestInProgress = false
                    self.model.permissionRepairing = false; self.permissionIssue(report.message)
                    self.finishFailedStartupRepair(beforeInitialPresentation); return
                }
                defaults.set(report.message, forKey: "permissions.repair.notice")
                self.accessibilityRepair.prepare(); defaults.synchronize()
                self.startupPresentation.beginRelaunch()
                self.restartInProgress = true
                NSApp.terminate(nil)
            } catch {
                self.accessibilityRepair.clear(); self.relaunch.cancel()
                self.permissionRequestInProgress = false; self.model.permissionRepairing = false
                self.permissionIssue(error.localizedDescription)
                self.finishFailedStartupRepair(beforeInitialPresentation)
            }
        }
    }
    func finishFailedStartupRepair(_ automatic: Bool) {
        guard automatic else { return }
        startupPresentation.finishPreparation()
        if !restorePermissionWindow() { showDefaultWindow() }
    }
    func restartApplication() {
        guard startupPresentation.canPresent, !restartInProgress && !permissionRequestInProgress && !preview else { return }
        rememberPermissionWindow()
        model.permissionMessage = ""; restartInProgress = true
        permissionAction = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.relaunch.arm(watchingPermission: false)
                UserDefaults.standard.synchronize()
                NSApp.terminate(nil)
            } catch {
                self.restartInProgress = false
                self.permissionIssue(error.localizedDescription)
            }
        }
    }
    @objc func translateSelection() { capture(read: false) }
    @objc func readSelection() { dismissSelectionBubble(); if model.readingActive { model.stopSpeaking(); return }; capture(read: true) }
    func capture(read: Bool) {
        if needsOnboarding || onboardingVisible { showOnboarding(); return }
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
                self.model.showIssue("尚未获得取词权限。可先粘贴文字使用，或前往设置开启辅助功能。", settingsTab: "权限")
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
        if needsOnboarding || onboardingVisible { showOnboarding(); return }
        if model.ocrBusy { cancelOCR(); return }
        guard CGPreflightScreenCaptureAccess() else {
            model.screenPermission = false
            model.showIssue("截图翻译需要屏幕录制权限，请在权限设置中开启。", settingsTab: "权限")
            showWindow(); return
        }
        let origin = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        captureTask?.cancel(); model.cancel(); dismissSelectionBubble()
        window.orderOut(nil); settings?.orderOut(nil)
        model.ocrBusy = true
        ocrID = UUID(); let id = ocrID
        ocrTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.ocrID == id {
                    self.model.ocrBusy = false; self.model.ocrRecognizing = false; self.ocrTask = nil
                    self.dismissSelectionBubble()
                }
            }
            do {
                let text = try await OCRService.capture {
                    guard self.ocrID == id else { return }
                    // Reset the old result without invoking model.cancel(), which
                    // would cancel this capture through the source didSet.
                    self.model.ocrBusy = false
                    self.model.setSource("", app: origin)
                    self.model.ocrBusy = true; self.model.ocrRecognizing = true
                    self.presentWindow(near: NSEvent.mouseLocation)
                }
                try Task.checkCancellation()
                guard self.ocrID == id, let text else { return }
                self.model.ocrBusy = false; self.model.ocrRecognizing = false
                self.model.setSource(text, app: origin)
                self.model.translate()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, self.ocrID == id else { return }
                self.model.ocrBusy = false; self.model.ocrRecognizing = false
                self.model.error = error.localizedDescription; self.showWindow()
            }
        }
    }
    func cancelOCR() {
        ocrID = UUID(); ocrTask?.cancel(); ocrTask = nil
        model.ocrBusy = false; model.ocrRecognizing = false
        dismissSelectionBubble()
    }
    func useSelection(_ text: String, app: String? = nil, readAfter: Bool = false) {
        dismissSelectionBubble(); captureTask?.cancel(); model.setSource(text, app: app); presentWindow(near: NSEvent.mouseLocation); model.translate()
    }
    func allowsSelectionLookup(pid: pid_t) -> Bool {
        guard !model.ocrBusy, !needsOnboarding, !onboardingVisible, model.mouseLookup,
              SelectionReader.trusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == pid, pid != ProcessInfo.processInfo.processIdentifier,
              !model.excludedApps.contains(app.bundleIdentifier ?? "") else { return false }
        return true
    }
    func onLocalMouseUp(_ event: NSEvent) {
        guard event.window === window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        finishLocalSelection(at: point, clicks: event.clickCount, shift: event.modifierFlags.contains(.shift))
    }
    func finishLocalSelection(at point: NSPoint, clicks: Int, shift: Bool) {
        guard model.mouseLookup, !model.ocrBusy, !needsOnboarding, !onboardingVisible else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let request = selectionLookup.finish(at: point, clicks: clicks, shift: shift, pid: pid) else { return }
        mouseTask?.cancel()
        mouseTask = Task { [weak self] in
            guard let self else { return }
            // Let NSTextView finish committing its selected range first.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, self.window.isKeyWindow, self.model.mouseLookup,
                  self.selectionLookup.accepts(request, frontPID: pid),
                  let text = LocalTextSelection.text(in: self.window, at: point) else { return }
            self.showBubble(text: text, point: point, app: self.model.sourceApp, local: true)
        }
    }
    func onMouseUp(_ event: NSEvent) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              allowsSelectionLookup(pid: app.processIdentifier) else {
            dismissSelectionBubble(); return
        }
        let point = event.locationInWindow
        let pid = app.processIdentifier
        guard let request = selectionLookup.finish(at: point, clicks: event.clickCount,
                                                   shift: event.modifierFlags.contains(.shift), pid: pid) else { return }
        mouseTask?.cancel()
        mouseTask = Task { [weak self] in
            guard let self else { return }
            let text = await SelectionLookup.resolve(read: {
                await SelectionReader.fromAccessibility(pid: pid, at: point)
            }, isValid: {
                self.allowsSelectionLookup(pid: pid) && self.selectionLookup.accepts(request,
                    frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            }, delays: SelectionReader.accessibilityProfile(pid: pid).retryDelays)
            guard let text, !Task.isCancelled else {
                if !Task.isCancelled, self.selectionLookup.accepts(request, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) {
                    self.selectionLog.debug("No accessible selection after bounded retries")
                }
                return
            }
            self.showBubble(text: text, point: point, app: app.bundleIdentifier)
        }
    }
    func onSelectionKeyDown(_ event: NSEvent, local: Bool = false) {
        let action = KeyboardSelectionAction.resolve(keyCode: event.keyCode, flags: event.modifierFlags,
            shortcuts: [model.translateShortcut, model.readShortcut, model.ocrShortcut])
        guard action != .ignore else { return }
        let pid = local ? ProcessInfo.processInfo.processIdentifier : NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid else { return }
        dismissSelectionBubble()
        keyboardSelection = (event.keyCode, pid, action)
    }
    func onSelectionKeyUp(_ event: NSEvent, local: Bool = false) {
        guard let gesture = keyboardSelection, gesture.code == event.keyCode else { return }
        keyboardSelection = nil
        guard gesture.action == .select || gesture.action == .inspect else { return }
        guard model.mouseLookup, !model.ocrBusy, !model.recordingShortcut, !needsOnboarding, !onboardingVisible else { return }
        if local {
            guard window.isKeyWindow else { return }
        } else {
            guard allowsSelectionLookup(pid: gesture.pid) else { return }
        }
        let request = selectionLookup.keyboard(pid: gesture.pid)
        let fallback = NSEvent.mouseLocation
        mouseTask?.cancel()
        mouseTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func valid() -> Bool {
                if local { return self.window.isKeyWindow && self.model.mouseLookup && self.selectionLookup.accepts(request, frontPID: gesture.pid) }
                return self.allowsSelectionLookup(pid: gesture.pid) && self.selectionLookup.accepts(request, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            }
            let text = await SelectionLookup.resolve(read: {
                if local {
                    guard let editor = self.window.firstResponder as? NSTextView else { return nil }
                    return LocalTextSelection.selectedText(in: editor)
                }
                // Keyboard selection follows focus, even when the pointer is
                // over another control. No clipboard fallback or simulated Copy.
                return await SelectionReader.fromAccessibility(pid: gesture.pid)
            }, isValid: valid, delays: local ? [80_000_000] : gesture.action == .select ? SelectionReader.accessibilityProfile(pid: gesture.pid).retryDelays : [180_000_000, 240_000_000])
            guard let text, !Task.isCancelled, valid() else { return }
            if gesture.action == .inspect, self.lastSelection?.pid == gesture.pid, self.lastSelection?.text == text { return }
            var point = fallback
            if local, let editor = self.window.firstResponder as? NSTextView {
                let rect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                if !rect.isEmpty { point = NSPoint(x: rect.minX, y: rect.minY) }
            } else if let anchor = await SelectionReader.selectionAnchor(pid: gesture.pid) { point = anchor }
            guard !Task.isCancelled, valid() else { return }
            self.showBubble(text: text, point: point, app: local ? self.model.sourceApp : NSRunningApplication(processIdentifier: gesture.pid)?.bundleIdentifier, local: local)
        }
    }
    @objc func translateService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receiveService(pasteboard, read: false, error: error)
    }
    @objc func readService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receiveService(pasteboard, read: true, error: error)
    }
    func receiveService(_ pasteboard: NSPasteboard, read: Bool, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if needsOnboarding || onboardingVisible { showOnboarding(); error.pointee = L10n.text("请先完成 Sonuvi 的首次设置。") as NSString; return }
        guard let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = L10n.text("请先选中文字。") as NSString; return
        }
        guard text.count <= 6000 else { error.pointee = L10n.text("单次最多支持 6000 个字符。") as NSString; return }
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
        mouseTask?.cancel(); mouseTask = nil; selectionLookup.invalidate()
        bubble?.orderOut(nil)
    }
    func showBubble(text: String, point: NSPoint, app: String?, local: Bool = false) {
        lastSelection = (local ? ProcessInfo.processInfo.processIdentifier : NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, text)
        if bubble == nil {
            bubble = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: 86, height: 42), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            bubble?.isOpaque = false; bubble?.backgroundColor = .clear; bubble?.hasShadow = true
            bubble?.level = .popUpMenu; bubble?.hidesOnDeactivate = false
            bubble?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        bubble?.contentView = NSHostingView(rootView: SelectionBubble(translate: { [weak self] in self?.useSelection(text, app: app) }, read: { [weak self] in
            guard let self else { return }; self.dismissSelectionBubble()
            self.captureTask?.cancel(); self.readingBar.anchor = point
            // Reading a local excerpt must not replace the complete source.
            if !local || TextRules.direction(text) == .toEnglish { self.model.setSource(text, app: app) }
            let presentation: ReadingPresentation = local ? .inline : .floating
            if TextRules.direction(text) == .toEnglish { self.model.translate(readAfter: true, presentation: presentation) }
            else { self.model.speak(text, presentation: presentation) }
        }))
        let frame = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame ?? NSScreen.main!.visibleFrame
        bubble?.setFrameOrigin(WindowGeometry.origin(near: point, size: NSSize(width: 86, height: 42), visible: frame)); bubble?.orderFrontRegardless()
    }
}

if CommandLine.arguments.contains("--voice-catalog-check") {
    do { let value = try VoicePackage.bundled(); print(String(data: try JSONEncoder().encode(value), encoding: .utf8)!); exit(0) }
    catch { fputs("Voice catalog verification failed\n", stderr); exit(1) }
}
else if CommandLine.arguments.contains("--voice-runtime-test") { Task { @MainActor in await runVoiceRuntimeTest() }; dispatchMain() }
else if CommandLine.arguments.contains("--voice-package-test") { Task { await runVoicePackageTests(); exit(0) }; dispatchMain() }
else if CommandLine.arguments.contains("--self-test") { runSelfTests() }
else if CommandLine.arguments.contains("--browser-test") { MainActor.assumeIsolated { let app = NSApplication.shared; Task { @MainActor in await runBrowserIntegrationTests(); exit(0) }; app.run() } }
else if CommandLine.arguments.contains("--preference-test") { MainActor.assumeIsolated { let app = NSApplication.shared; Task { @MainActor in await runPreferenceInteractionTests(); exit(0) }; app.run() } }
else if CommandLine.arguments.contains("--onboarding-layout-test") { MainActor.assumeIsolated { let app = NSApplication.shared; Task { @MainActor in await runOnboardingLayoutTests(); exit(0) }; app.run() } }
else if CommandLine.arguments.contains("--translation-layout-test") { MainActor.assumeIsolated { let app = NSApplication.shared; Task { @MainActor in await runTranslationLayoutTests(); exit(0) }; app.run() } }
else if CommandLine.arguments.contains("--permission-test") { Task { @MainActor in await runPermissionTests(); exit(0) }; dispatchMain() }
else if CommandLine.arguments.contains("--selection-test") { MainActor.assumeIsolated { let app = NSApplication.shared; Task { @MainActor in await runSelectionTests(); exit(0) }; app.run() } }
else if CommandLine.arguments.contains("--editor-test") { MainActor.assumeIsolated { runEditorTests() } }
else if CommandLine.arguments.contains("--ocr-pipeline-test") { Task { await runOCRPipelineTest(); exit(0) }; dispatchMain() }
else if CommandLine.arguments.contains("--ocr-test") { runOCRTest() }
else if CommandLine.arguments.contains("--network-test") { Task { await runNetworkTests(); exit(0) }; dispatchMain() }
else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared; let delegate = AppDelegate(); application.delegate = delegate; application.run()
    }
}
