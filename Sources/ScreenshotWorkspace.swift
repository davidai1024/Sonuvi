// Sonuvi — GPL-3.0. A frozen screenshot workspace, not a collection of floating labels.
import AppKit
import ApplicationServices
import Combine
import SwiftUI

enum ScreenshotHandle: Int, CaseIterable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}
enum ScreenshotWorkspaceGeometry {
    static func cursorRegion(_ rect: CGRect, within bounds: CGRect) -> CGRect? {
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty,
              [clipped.minX, clipped.minY, clipped.width, clipped.height].allSatisfy(\.isFinite) else { return nil }
        return clipped
    }
    static func edited(_ rect: CGRect, delta: CGSize, handle: ScreenshotHandle?, within limit: CGRect) -> CGRect {
        guard let handle else {
            return CGRect(x: max(limit.minX, min(rect.minX + delta.width, limit.maxX - rect.width)),
                          y: max(limit.minY, min(rect.minY + delta.height, limit.maxY - rect.height)), width: rect.width, height: rect.height)
        }
        var left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY
        if [.bottomLeft, .left, .topLeft].contains(handle) { left = max(limit.minX, min(right - 24, left + delta.width)) }
        if [.bottomRight, .right, .topRight].contains(handle) { right = min(limit.maxX, max(left + 24, right + delta.width)) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = max(limit.minY, min(top - 24, bottom + delta.height)) }
        if [.topLeft, .top, .topRight].contains(handle) { top = min(limit.maxY, max(bottom + 24, top + delta.height)) }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

// AppKit controls inherit the Mac's appearance, contrast, focus and accent color.
final class ScreenshotWorkspaceToolbar: NSVisualEffectView {
    private let model: ScreenshotOverlayModel
    private let languageChanged: () -> Void
    private let actions: [() -> Void]
    private let language = NSPopUpButton(frame: .zero, pullsDown: false)
    private let original = NSButton()
    private let copyButton = NSButton()
    private let more = NSButton()
    init(model: ScreenshotOverlayModel, languageChanged: @escaping () -> Void,
         copy: @escaping () -> Void, copyImage: @escaping () -> Void, open: @escaping () -> Void,
         reselect: @escaping () -> Void, retry: @escaping () -> Void, close: @escaping () -> Void, settings: @escaping () -> Void) {
        self.model = model; self.languageChanged = languageChanged
        actions = [copy, copyImage, open, reselect, retry, close, settings]
        super.init(frame: .zero)
        material = .popover; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 10; layer?.masksToBounds = true
        layer?.borderWidth = 0.5; layer?.borderColor = NSColor.separatorColor.cgColor
        language.controlSize = .small
        language.addItems(withTitles: ScreenshotLanguage.allCases.map { L10n.text($0 == .automatic ? "自动选择译文语言" : $0.rawValue) })
        language.target = self; language.action = #selector(changeLanguage)
        language.toolTip = L10n.text("译文语言"); language.setAccessibilityLabel(L10n.text("译文语言"))
        original.title = L10n.text("对照"); original.setButtonType(.pushOnPushOff); original.bezelStyle = .rounded
        original.target = self; original.action = #selector(toggleOriginal)
        original.toolTip = L10n.text("切换原文与译文；按住 Option 临时查看原文")
        copyButton.title = L10n.text("复制文字"); copyButton.bezelStyle = .rounded
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading; copyButton.target = self; copyButton.action = #selector(performAction(_:)); copyButton.tag = 0
        more.isBordered = false; more.target = self; more.action = #selector(showMore)
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L10n.text("更多"))
        more.imagePosition = .imageOnly; more.toolTip = L10n.text("更多"); more.setAccessibilityLabel(L10n.text("更多"))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("关闭截图翻译"))!, target: self, action: #selector(performAction(_:)))
        close.isBordered = false; close.tag = 5; close.toolTip = L10n.text("关闭截图翻译")
        let stack = NSStackView(views: [language, original, copyButton, more, close])
        stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            language.widthAnchor.constraint(equalToConstant: 110), more.widthAnchor.constraint(equalToConstant: 25), close.widthAnchor.constraint(equalToConstant: 24)])
        for button in [original, copyButton, close] { button.controlSize = .small; button.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changeLanguage() { model.targetLanguage = ScreenshotLanguage.allCases[language.indexOfSelectedItem]; languageChanged() }
    @objc private func toggleOriginal() { model.original.toggle() }
    @objc private func performAction(_ sender: NSControl) { actions[sender.tag]() }
    @objc private func showMore() { more.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: more) }
    @objc private func menuAction(_ sender: NSMenuItem) {
        if sender.tag == 7 { model.pinned.toggle() }
        else if sender.tag == 8 { model.selectingText.toggle() }
        else { actions[sender.tag]() }
    }
    func update() {
        language.selectItem(at: ScreenshotLanguage.allCases.firstIndex(of: model.targetLanguage) ?? 0)
        // Compact language names keep the toolbar stable as OCR finishes.
        language.selectedItem?.title = L10n.text(model.targetLanguage == .automatic ? "自动" : model.targetLanguage.rawValue)
        original.state = model.original ? .on : .off
        copyButton.title = L10n.text(model.copied ? "已复制" : "复制文字"); copyButton.isEnabled = !model.copyText.isEmpty
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ tag: Int, enabled: Bool = true, checked: Bool = false) {
            let value = NSMenuItem(title: L10n.text(title), action: #selector(menuAction(_:)), keyEquivalent: "")
            value.target = self; value.tag = tag; value.isEnabled = enabled; value.state = checked ? .on : .off; menu.addItem(value)
        }
        item("复制图片", 1, enabled: model.original || (!model.busy && !model.overflow && model.error.isEmpty))
        item("固定截图", 7, checked: model.pinned); item("拖动模式", 8, checked: !model.selectingText)
        menu.addItem(.separator()); item("重新框选", 3); item("在窗口查看", 2, enabled: model.document != nil)
        if model.needsSettings { item("打开模型设置", 6) } else if !model.error.isEmpty { item("重试", 4) }
        more.menu = menu; more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L10n.text("更多"))
    }
}

private final class ScreenshotWorkspacePanel: NSPanel {
    var escape: (() -> Void)?
    var copy: (() -> Void)?
    var peek: ((Bool) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { escape?(); return true }
        if let text = firstResponder as? NSTextView, TextEditingCommands.perform(event, in: text) { return true }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { copy?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { escape?() } else { super.keyDown(with: event) } }
    override func flagsChanged(with event: NSEvent) { peek?(event.modifierFlags.contains(.option)); super.flagsChanged(with: event) }
}

private final class ScreenshotWorkspaceView: NSView {
    let shade = CAShapeLayer()
    let border = CAShapeLayer()
    let handles = CAShapeLayer()
    let loading = NSView()
    let spinner = NSProgressIndicator()
    let status = NSTextField(labelWithString: "")
    var canvas: ScreenshotCanvasView
    var toolbar: NSView?
    var backdrop: CGImage?
    var selection = CGRect.zero // Local to this panel.
    var globalFrame = CGRect.zero
    var editLimit = CGRect.zero
    var selectingText = false
    var pinned = false
    var edited: ((CGRect, Bool, Bool) -> Void)?
    var cancelled: (() -> Void)?
    private var anchor: CGPoint?
    private var initial = CGRect.zero
    private var handle: ScreenshotHandle?
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage, size: CGSize) {
        canvas = ScreenshotCanvasView(image: image, size: size)
        super.init(frame: .zero); wantsLayer = true
        layer?.contentsGravity = .resize; layer?.magnificationFilter = .nearest; layer?.minificationFilter = .nearest
        shade.fillRule = .evenOdd; shade.fillColor = NSColor.black.withAlphaComponent(0.53).cgColor
        border.strokeColor = NSColor.controlAccentColor.cgColor; border.fillColor = nil; border.lineWidth = 1
        handles.strokeColor = NSColor.controlAccentColor.cgColor; handles.fillColor = NSColor.white.cgColor; handles.lineWidth = 1
        layer?.addSublayer(shade); addSubview(canvas)
        loading.wantsLayer = true; loading.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12, weight: .medium); status.textColor = .white; status.alignment = .center
        status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping
        loading.addSubview(spinner); loading.addSubview(status); addSubview(loading)
        layer?.addSublayer(border); layer?.addSublayer(handles)
        setAccessibilityLabel(L10n.text("截图翻译工作区"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for layer in [layer, shade, border, handles].compactMap({ $0 }) { layer.contentsScale = window?.backingScaleFactor ?? 2 }
    }
    func update(selection: CGRect, model: ScreenshotOverlayModel) {
        self.selection = selection; selectingText = model.selectingText; pinned = model.pinned
        canvas.frame = selection; loading.frame = selection
        let path = CGMutablePath(); path.addRect(bounds); path.addRect(selection)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shade.path = path; shade.isHidden = pinned
        border.path = CGPath(rect: selection, transform: nil)
        let dots = CGMutablePath()
        for handle in ScreenshotHandle.allCases {
            let point = handle.point(in: selection); dots.addEllipse(in: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
        }
        handles.path = dots
        CATransaction.commit()
        loading.isHidden = !model.busy && model.error.isEmpty && !model.editing
        status.stringValue = L10n.text(model.error.isEmpty ? (model.editing ? "松开以更新选区" : model.status) : model.error)
        let width = min(max(80, selection.width - 24), 420)
        status.frame = CGRect(x: (selection.width - width) / 2, y: selection.height / 2 - 34, width: width, height: 40)
        spinner.frame = CGRect(x: selection.width / 2 - 8, y: selection.height / 2 + 10, width: 16, height: 16)
        if model.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        window?.invalidateCursorRects(for: self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let toolbar, toolbar.frame.contains(point) { return super.hitTest(point) }
        if ScreenshotHandle.allCases.contains(where: { let p = $0.point(in: selection); return abs(p.x-point.x) <= 7 && abs(p.y-point.y) <= 7 }) { return self }
        if selection.contains(point) && !selection.insetBy(dx: 5, dy: 5).contains(point) { return self }
        if selectingText && selection.contains(point), let hit = super.hitTest(point), hit is NSTextView || hit is NSClipView || hit is NSScroller { return hit }
        // Empty image space and the border drag the result; text selects immediately.
        return self
    }
    override func resetCursorRects() {
        if !selectingText, let rect = ScreenshotWorkspaceGeometry.cursorRegion(selection, within: bounds) { addCursorRect(rect, cursor: .openHand) }
        for handle in ScreenshotHandle.allCases {
            let p = handle.point(in: selection)
            if let rect = ScreenshotWorkspaceGeometry.cursorRegion(CGRect(x: p.x-7, y: p.y-7, width: 14, height: 14), within: bounds) {
                addCursorRect(rect, cursor: [.left, .right].contains(handle) ? .resizeLeftRight : [.top, .bottom].contains(handle) ? .resizeUpDown : .crosshair)
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handle = ScreenshotHandle.allCases.first { let p = $0.point(in: selection); return abs(p.x-point.x) <= 7 && abs(p.y-point.y) <= 7 }
        guard selection.contains(point) || handle != nil else { return }
        anchor = window?.convertPoint(toScreen: event.locationInWindow)
        initial = selection.offsetBy(dx: globalFrame.minX, dy: globalFrame.minY)
        window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) { drag(event, ended: false) }
    override func mouseUp(with event: NSEvent) { drag(event, ended: true); anchor = nil }
    private func drag(_ event: NSEvent, ended: Bool) {
        guard let anchor, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        let rect = ScreenshotWorkspaceGeometry.edited(initial, delta: CGSize(width: point.x-anchor.x, height: point.y-anchor.y), handle: handle, within: editLimit)
        edited?(rect, handle != nil, ended)
    }
    override func rightMouseDown(with event: NSEvent) { cancelled?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { cancelled?() } else { super.keyDown(with: event) } }
}

@MainActor
final class ScreenshotTranslationController {
    let model = ScreenshotOverlayModel()
    private(set) var image: CGImage
    private(set) var selection: CGRect
    private var captureRect: CGRect
    private let snapshot: FrozenCapture
    private let modelName: String
    private var panels: [(ScreenshotWorkspacePanel, ScreenshotWorkspaceView, CGRect)] = []
    private var toolbar: ScreenshotWorkspaceToolbar?
    private var task: Task<Void, Never>?
    private var work: ScreenshotTranslationWork?
    private var cache: [String: String] = [:]
    private var observation: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private var revision = UUID()
    private var refreshing = false
    private var closed = false
    private var recordedCompletion = false
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    var onCompleted: ((ScreenshotDocument) -> Void)?
    var onCopy: (() -> Void)?
    var onOpenWindow: ((ScreenshotDocument, String, Bool) -> Void)?
    // Fixtures can exercise the identical production workspace without credentials or external requests.
    var sendOverride: ScreenshotTranslationWork.Send?
    var recognizeOverride: ((CGImage) async throws -> ScreenshotDocument)?
    init(image: CGImage, selection: CGRect, modelName: String, snapshot: FrozenCapture? = nil) {
        self.image = image; self.selection = selection; captureRect = selection; self.modelName = modelName
        self.snapshot = snapshot ?? FrozenCapture(frame: selection, image: image)
    }
    func show() {
        guard panels.isEmpty, !closed else { return }
        for screen in NSScreen.screens {
            guard let backdrop = snapshot.crop(screen.frame) else { continue }
            let panel = ScreenshotWorkspacePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.level = .screenSaver; panel.hidesOnDeactivate = false; panel.hasShadow = false; panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.escape = { [weak self] in self?.close() }; panel.peek = { [weak self] in self?.model.peeking = $0 }
            panel.copy = { [weak self] in self?.copyImage() }
            let view = ScreenshotWorkspaceView(image: image, size: selection.size); view.frame = CGRect(origin: .zero, size: screen.frame.size)
            view.backdrop = backdrop; view.layer?.contents = backdrop; view.globalFrame = screen.frame; view.editLimit = snapshot.frame
            view.edited = { [weak self] rect, resize, ended in self?.edit(rect, resizing: resize, ended: ended) }
            view.cancelled = { [weak self] in self?.close() }
            panel.contentView = view; panels.append((panel, view, screen.frame)); panel.orderFrontRegardless()
        }
        observation = model.objectWillChange.sink { [weak self] _ in
            guard let self, !self.refreshing else { return }; self.refreshing = true
            DispatchQueue.main.async { [weak self] in self?.refreshing = false; self?.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.close() } })
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.close() } }
        refresh()
        if let host = panels.first(where: { $0.2.contains(CGPoint(x: selection.midX, y: selection.midY)) }) ?? panels.first {
            host.0.orderFrontRegardless(); host.0.makeKey(); host.0.makeFirstResponder(host.1)
        }
        start()
    }
    private func makeToolbar() -> ScreenshotWorkspaceToolbar {
        ScreenshotWorkspaceToolbar(model: model, languageChanged: { [weak self] in self?.languageChanged() },
            copy: { [weak self] in self?.copy() }, copyImage: { [weak self] in self?.copyImage() }, open: { [weak self] in self?.openWindow() },
            reselect: { [weak self] in self?.reselect() }, retry: { [weak self] in self?.start() }, close: { [weak self] in self?.close() },
            settings: { [weak self] in let callback = self?.onSettings; self?.close(); callback?() })
    }
    private func refresh() {
        guard !closed, !panels.isEmpty else { return }
        let host = panels.firstIndex(where: { $0.2.contains(CGPoint(x: selection.midX, y: selection.midY)) }) ?? 0
        let screen = NSScreen.screens.first(where: { $0.frame == panels[host].2 })?.visibleFrame ?? panels[host].2
        let width = min(360, screen.width - 16)
        let barFrame = ScreenshotLayout.toolbarFrame(selection: selection, screen: screen, size: CGSize(width: width, height: 38))
        if toolbar == nil { toolbar = makeToolbar() }; toolbar?.update()
        var overflow = false
        for (index, entry) in panels.enumerated() {
            let (panel, view, frame) = entry
            if model.pinned && index != host { panel.orderOut(nil); continue }
            let targetFrame = model.pinned ? selection.union(barFrame).insetBy(dx: -8, dy: -8) : frame
            if panel.frame != targetFrame { panel.setFrame(targetFrame, display: true) }
            view.globalFrame = targetFrame
            view.layer?.contents = model.pinned ? nil : view.backdrop
            view.update(selection: selection.offsetBy(dx: -targetFrame.minX, dy: -targetFrame.minY), model: model)
            overflow = view.canvas.update(document: model.document, values: model.completed, original: model.showsOriginal) || overflow
            if index == host, let toolbar {
                if toolbar.superview !== view { toolbar.removeFromSuperview(); view.addSubview(toolbar); view.toolbar = toolbar }
                toolbar.frame = barFrame.offsetBy(dx: -targetFrame.minX, dy: -targetFrame.minY)
            } else { view.toolbar = nil }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        if model.overflow != overflow { model.overflow = overflow }
    }
    private func replaceCanvas() {
        for (_, view, _) in panels {
            let old = view.canvas; let new = ScreenshotCanvasView(image: image, size: selection.size)
            view.addSubview(new, positioned: .above, relativeTo: old); old.removeFromSuperview(); view.canvas = new
        }
    }
    func edit(_ rect: CGRect, resizing: Bool, ended: Bool) {
        guard !closed else { return }
        if resizing {
            captureRect = CGRect(x: captureRect.minX + rect.minX-selection.minX, y: captureRect.minY + rect.minY-selection.minY, width: rect.width, height: rect.height)
            model.editing = !ended
        }
        let changed = rect != selection; selection = rect; refresh()
        if resizing && ended, changed || model.document != nil {
            let aligned = snapshot.alignedRect(captureRect)
            guard let cropped = snapshot.crop(aligned) else { return }
            captureRect = aligned; image = cropped
            selection.size = aligned.size; model.document = nil; model.completed = [:]; model.visible = [:]; work = nil
            replaceCanvas(); start()
        }
    }
    private var direction: Direction? {
        model.resolvedTarget.direction
    }
    func languageChanged() { task?.cancel(); revision = UUID(); work = nil; model.completed = [:]; model.visible = [:]; model.original = false; start() }
    private func swapLanguages() {
        let oldTarget = model.resolvedTarget
        let oldSource = model.detectedSource
        model.sourceLanguage = oldTarget; model.targetLanguage = oldSource; languageChanged()
    }
    func reselect() {
        guard !closed else { return }
        task?.cancel(); revision = UUID(); model.pinned = false
        for (panel, _, _) in panels { panel.orderOut(nil) }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let selected = try await ScreenSelection().select(snapshot: self.snapshot) else {
                    if self.model.busy { self.start() }; self.refresh(); return
                }
                self.captureRect = self.snapshot.alignedRect(selected); self.selection = self.captureRect
                guard let image = self.snapshot.crop(self.captureRect) else { self.refresh(); return }
                self.image = image; self.model.document = nil; self.model.completed = [:]; self.model.visible = [:]; self.work = nil
                self.replaceCanvas(); self.start(); self.refresh()
            } catch { if !self.closed { self.refresh() } }
        }
    }
    func start() {
        guard !closed else { return }
        task?.cancel(); revision = UUID(); let current = revision
        model.busy = true; model.error = ""; model.copied = false; model.needsSettings = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if self.model.document == nil {
                    self.model.status = "正在识别截图文字…"
                    let document: ScreenshotDocument
                    if let recognize = self.recognizeOverride { document = try await recognize(self.image) }
                    else { document = try await OCRService.recognizeDocument(.image(self.image)) }
                    try Task.checkCancellation(); guard current == self.revision else { return }
                    guard !document.regions.isEmpty else { throw TranslateError.message("没有识别到文字，请重新框选清晰的区域。") }
                    self.model.document = document
                }
                guard let document = self.model.document else { return }
                if self.work == nil { self.work = ScreenshotTranslationWork(document: document, direction: self.direction, cache: self.cache) }
                guard let work = self.work else { return }
                let sender: ScreenshotTranslationWork.Send
                if work.completed.count == document.regions.count { sender = { text, _, _ in text } }
                else if let override = self.sendOverride { sender = override }
                else {
                    let key = try KeyStore.read()
                    let name = self.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    sender = { text, direction, update in
                        let request = try DeepSeekClient.screenshotRequest(text: text, direction: direction, model: name.isEmpty ? "deepseek-flash" : name, key: key)
                        return try await DeepSeekClient.stream(request, onDelta: update)
                    }
                }
                try await work.run(send: sender, onUpdate: { [weak self] values in
                    guard let self, !self.closed, current == self.revision, !Task.isCancelled else { return }; self.model.visible = values
                }, onProgress: { [weak self] done, total, retry in
                    guard let self, !self.closed, current == self.revision, !Task.isCancelled else { return }
                    self.model.status = retry ? "服务繁忙，正在自动重试…" : "正在翻译 \(done)/\(total) 个区域…"
                })
                try Task.checkCancellation(); guard current == self.revision else { return }
                self.model.completed = work.completed; self.model.busy = false
                self.model.status = "翻译完成 · 拖动选区移动 · Esc 关闭"
                for region in document.regions {
                    if let value = work.completed[region.id] { self.cache[ScreenshotTranslationWork.cacheKey(region.text, direction: self.direction ?? region.direction)] = value }
                }
                if !self.recordedCompletion { self.recordedCompletion = true; self.onCompleted?(document) }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, !self.closed, current == self.revision else { return }
                self.model.completed = self.work?.completed ?? [:]; self.model.busy = false
                self.model.error = error.localizedDescription; self.model.needsSettings = error is KeyAccessError
            }
        }
    }
    func copy(to board: NSPasteboard = .general) {
        guard !model.copyText.isEmpty else { return }
        board.clearContents(); board.setString(model.copyText, forType: .string); model.copied = true; onCopy?()
    }
    func copyImage(to board: NSPasteboard = .general) {
        guard model.original || (!model.busy && !model.overflow && model.error.isEmpty),
              let result = ScreenshotImageRenderer.render(image: image, size: selection.size, document: model.document, values: model.completed, original: model.original),
              let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else { return }
        board.clearContents(); board.setData(data, forType: .png); model.copied = true; onCopy?()
    }
    private func openWindow() {
        guard let document = model.document else { return }
        let text = document.regions.map { model.completed[$0.id] ?? $0.text }.joined(separator: "\n\n")
        let complete = model.completed.count == document.regions.count; let callback = onOpenWindow
        close(); callback?(document, text, complete)
    }
    func close() {
        guard !closed else { return }; closed = true; revision = UUID(); task?.cancel(); task = nil; observation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }; spaceObserver = nil
        for (panel, _, _) in panels { panel.orderOut(nil) }; panels.removeAll(); toolbar = nil; onClose?()
    }
}
