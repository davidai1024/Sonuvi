// Sonuvi — GPL-3.0. Frozen pixels with selectable, locally positioned translations.
import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class ScreenshotOverlayModel: ObservableObject {
    @Published var document: ScreenshotDocument?
    @Published var visible: [Int: String] = [:]
    @Published var completed: [Int: String] = [:]
    @Published var original = false
    @Published var busy = true
    @Published var error = ""
    @Published var status = "正在识别截图文字…"
    @Published var overflow = false
    @Published var copied = false
    @Published var needsSettings = false
    var copyText: String {
        guard let document else { return "" }
        return original ? document.text : document.regions.compactMap { completed[$0.id] }.joined(separator: "\n\n")
    }
}

struct ScreenshotRegionColors {
    let background: NSColor
    let foreground: NSColor
    static func sample(image: CGImage, rect: CGRect, size: CGSize) -> ScreenshotRegionColors {
        let cropped = CapturedDisplay(frame: CGRect(origin: .zero, size: size), image: image).crop(rect) ?? image
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let result: (CGFloat, CGFloat, CGFloat) = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return (1,1,1) }
            context.interpolationQuality = .none; context.draw(cropped, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let data = bytes.bindMemory(to: UInt8.self)
            var buckets: [Int: (Int, Int, Int, Int)] = [:]
            for index in stride(from: 0, to: data.count, by: 4) where data[index + 3] > 200 {
                let r = Int(data[index]), g = Int(data[index + 1]), b = Int(data[index + 2])
                let key = (r / 32) * 64 + (g / 32) * 8 + b / 32
                let old = buckets[key] ?? (0,0,0,0); buckets[key] = (old.0 + 1, old.1 + r, old.2 + g, old.3 + b)
            }
            guard let best = buckets.values.max(by: { $0.0 < $1.0 }) else { return (1,1,1) }
            let denominator = CGFloat(best.0) * 255
            return (CGFloat(best.1) / denominator, CGFloat(best.2) / denominator, CGFloat(best.3) / denominator)
        }
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let brightness = 0.2126 * linear(result.0) + 0.7152 * linear(result.1) + 0.0722 * linear(result.2)
        return ScreenshotRegionColors(background: NSColor(srgbRed: result.0, green: result.1, blue: result.2, alpha: 1),
                                      foreground: brightness > 0.179 ? .black : .white)
    }
}

@MainActor
enum ScreenshotImageRenderer {
    static func render(image: CGImage, size: CGSize, document: ScreenshotDocument?, values: [Int: String], original: Bool) -> CGImage? {
        if original { return image }
        guard let document, size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for region in document.regions {
            guard let text = values[region.id], !text.isEmpty else { continue }
            let placement = ScreenshotLayout.placement(region: region, text: text, regions: document.regions, size: size)
            guard !placement.scrolls else { return nil } // Do not export clipped translations as a complete image.
            let color = ScreenshotRegionColors.sample(image: image, rect: ScreenshotLayout.rect(region.bounds, in: size).insetBy(dx: -2, dy: -2), size: size)
            context.saveGState(); context.clip(to: placement.frame)
            color.background.setFill(); placement.frame.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: placement.fontSize), .foregroundColor: color.foreground]
            NSAttributedString(string: text, attributes: attributes).draw(with: placement.frame.insetBy(dx: 2, dy: 2),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            context.restoreGState()
        }
        return context.makeImage()
    }
}

@MainActor
final class ScreenshotCanvasView: NSView {
    let image: CGImage
    private var textViews: [Int: NSScrollView] = [:]
    private var lastText: [Int: String] = [:]
    private var colors: [Int: ScreenshotRegionColors] = [:]
    init(image: CGImage, size: CGSize) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true; layer?.contents = image; layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest; layer?.minificationFilter = .nearest
        setAccessibilityLabel(L10n.text("截图翻译结果"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); layer?.contentsScale = window?.backingScaleFactor ?? 2 }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); layer?.contentsScale = window?.backingScaleFactor ?? 2 }
    func update(document: ScreenshotDocument?, values: [Int: String], original: Bool) -> Bool {
        guard let document else { return false }
        var overflow = false
        for region in document.regions {
            guard let value = values[region.id], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                textViews[region.id]?.isHidden = true; continue
            }
            let placement = ScreenshotLayout.placement(region: region, text: value, regions: document.regions, size: bounds.size)
            overflow = overflow || placement.scrolls
            if let scroll = textViews[region.id], lastText[region.id] == value {
                scroll.isHidden = original; continue
            }
            let scroll: NSScrollView
            let text: NSTextView
            if let existing = textViews[region.id], let editor = existing.documentView as? NSTextView { scroll = existing; text = editor }
            else {
                scroll = NSScrollView(); scroll.borderType = .noBorder; scroll.drawsBackground = true
                scroll.scrollerStyle = .overlay; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 2
                text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.isRichText = false
                text.drawsBackground = false; text.textContainerInset = NSSize(width: 2, height: 2)
                text.textContainer?.lineFragmentPadding = 0; text.textContainer?.widthTracksTextView = true
                text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
                text.setAccessibilityLabel(L10n.text("区域译文"))
                scroll.documentView = text; textViews[region.id] = scroll; addSubview(scroll)
            }
            let color = colors[region.id] ?? ScreenshotRegionColors.sample(image: image,
                rect: ScreenshotLayout.rect(region.bounds, in: bounds.size).insetBy(dx: -2, dy: -2), size: bounds.size)
            colors[region.id] = color
            scroll.frame = placement.frame; scroll.backgroundColor = color.background
            scroll.hasVerticalScroller = placement.scrolls; scroll.isHidden = original
            text.frame = CGRect(x: 0, y: 0, width: placement.frame.width, height: max(placement.frame.height, placement.contentHeight))
            text.textContainer?.containerSize = NSSize(width: max(1, placement.frame.width - 4), height: CGFloat.greatestFiniteMagnitude)
            if let storage = text.textStorage { StreamingTextUpdate.apply(value, to: storage) }
            text.font = .systemFont(ofSize: placement.fontSize); text.textColor = color.foreground
            text.toolTip = value; lastText[region.id] = value
        }
        return overflow
    }
}

private struct ScreenshotCanvas: NSViewRepresentable {
    let model: ScreenshotOverlayModel
    let image: CGImage
    let size: CGSize
    @ObservedObject private var observed: ScreenshotOverlayModel
    init(model: ScreenshotOverlayModel, image: CGImage, size: CGSize) { self.model = model; self.image = image; self.size = size; observed = model }
    func makeNSView(context: Context) -> ScreenshotCanvasView { ScreenshotCanvasView(image: image, size: size) }
    func updateNSView(_ view: ScreenshotCanvasView, context: Context) {
        let overflow = view.update(document: observed.document, values: observed.visible, original: observed.original)
        if overflow != observed.overflow { DispatchQueue.main.async { model.overflow = overflow } }
    }
}

private final class ScreenshotOverlayPanel: NSPanel {
    var closeOverlay: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { closeOverlay?(); return true }
        if let editor = firstResponder as? NSTextView, TextEditingCommands.perform(event, in: editor) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { closeOverlay?() } else { super.keyDown(with: event) } }
}

private struct ScreenshotToolbar: View {
    @ObservedObject var model: ScreenshotOverlayModel
    let copy: () -> Void
    let copyImage: () -> Void
    let open: () -> Void
    let retry: () -> Void
    let close: () -> Void
    let settings: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder").foregroundStyle(.secondary)
                LText("截图翻译").font(.system(size: 12, weight: .semibold))
                if model.busy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 4)
                Picker(L10n.text("显示内容"), selection: $model.original) {
                    LText("译文").tag(false); LText("原文").tag(true)
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 152).disabled(model.document == nil)
                Button(action: close) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).help(L10n.text("关闭截图翻译 · Esc")).accessibilityLabel(L10n.text("关闭截图翻译"))
            }
            HStack(spacing: 10) {
                LText(model.error.isEmpty ? (model.copied ? "已复制" : (model.overflow && !model.busy ? "译文较长，可滚动或在窗口查看" : model.status)) : model.error)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if model.needsSettings { Button(L10n.text("打开模型设置"), action: settings).controlSize(.small) }
                else if !model.error.isEmpty { Button(L10n.text("重试"), action: retry).controlSize(.small) }
                Menu {
                    Button(L10n.text(model.original ? "复制原文" : "复制译文文字"), action: copy).disabled(model.copyText.isEmpty)
                    Button(L10n.text(model.original ? "复制原图" : "复制译文图片"), action: copyImage)
                        .disabled(!model.original && (model.busy || model.overflow || !model.error.isEmpty))
                } label: {
                    LText(model.original ? "复制原文" : "复制译文")
                } primaryAction: { copy() }
                .controlSize(.small).disabled(model.document == nil)
                Button(L10n.text("在窗口查看"), action: open).controlSize(.small).disabled(model.document == nil)
            }
        }.padding(12).frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
final class ScreenshotTranslationController {
    let model = ScreenshotOverlayModel()
    let image: CGImage
    let selection: CGRect
    private var panel: ScreenshotOverlayPanel?
    private var toolbar: ScreenshotOverlayPanel?
    private var task: Task<Void, Never>?
    private var work: ScreenshotTranslationWork?
    private var observer: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var closed = false
    private var recordedCompletion = false
    private let modelName: String
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    var onCompleted: ((ScreenshotDocument) -> Void)?
    var onCopy: (() -> Void)?
    var onOpenWindow: ((ScreenshotDocument, String, Bool) -> Void)?
    init(image: CGImage, selection: CGRect, modelName: String) { self.image = image; self.selection = selection; self.modelName = modelName }
    func show() {
        let panel = ScreenshotOverlayPanel(contentRect: selection, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(panel); panel.hasShadow = false
        let content = NSHostingView(rootView: ScreenshotCanvas(model: model, image: image, size: selection.size))
        if #available(macOS 14.0, *) { content.safeAreaRegions = [] }
        panel.contentView = content; self.panel = panel
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: selection.midX, y: selection.midY)) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? selection
        let size = CGSize(width: min(540, max(280, visible.width - 16)), height: 84)
        let toolbar = ScreenshotOverlayPanel(contentRect: ScreenshotLayout.toolbarFrame(selection: selection, screen: visible, size: size),
                                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(toolbar); toolbar.hasShadow = true; toolbar.isMovableByWindowBackground = true
        toolbar.contentView = NSHostingView(rootView: LocalizedRoot(content: ScreenshotToolbar(model: model,
            copy: { [weak self] in self?.copy() }, copyImage: { [weak self] in self?.copyImage() }, open: { [weak self] in self?.openWindow() },
            retry: { [weak self] in self?.start() }, close: { [weak self] in self?.close() },
            settings: { [weak self] in let callback = self?.onSettings; self?.close(); callback?() })))
        self.toolbar = toolbar
        panel.orderFrontRegardless(); toolbar.orderFrontRegardless(); toolbar.makeKey()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        if AXIsProcessTrusted() {
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { Task { @MainActor in self?.close() } }
            }
        }
        start()
    }
    private func configure(_ panel: ScreenshotOverlayPanel) {
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = .statusBar; panel.hidesOnDeactivate = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.closeOverlay = { [weak self] in self?.close() }
    }
    func start() {
        guard !closed else { return }
        task?.cancel(); model.busy = true; model.error = ""; model.copied = false; model.needsSettings = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if self.model.document == nil {
                    self.model.status = "正在识别截图文字…"
                    let document = try await OCRService.recognizeDocument(.image(self.image))
                    try Task.checkCancellation()
                    guard !document.regions.isEmpty else { throw TranslateError.message("没有识别到文字，请重新框选清晰的区域。") }
                    self.model.document = document; self.work = ScreenshotTranslationWork(document: document)
                }
                guard let work = self.work else { return }
                let key = try KeyStore.read()
                let name = self.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                try await work.run(send: { text, direction, update in
                    let request = try DeepSeekClient.request(text: text, kind: .sentence, direction: direction, model: name.isEmpty ? "deepseek-flash" : name, key: key)
                    return try await DeepSeekClient.stream(request, onDelta: update)
                }, onUpdate: { [weak self] values in
                    guard let self, !self.closed, !Task.isCancelled else { return }
                    self.model.visible = values
                }, onProgress: { [weak self] done, total, retry in
                    guard let self, !self.closed, !Task.isCancelled else { return }
                    self.model.completed = work.completed
                    self.model.status = retry ? "服务繁忙，正在自动重试…" : "正在翻译 \(done)/\(total) 个区域…"
                })
                try Task.checkCancellation()
                self.model.completed = work.completed; self.model.busy = false
                self.model.status = self.model.overflow ? "译文较长，可滚动或在窗口查看" : "翻译完成 · 可选中文字复制 · Esc 关闭"
                if !self.recordedCompletion { self.recordedCompletion = true; self.onCompleted?(work.document) }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, !self.closed else { return }
                self.model.busy = false; self.model.error = error.localizedDescription; self.model.needsSettings = error is KeyAccessError
            }
        }
    }
    func copy(to board: NSPasteboard = .general) {
        guard !model.copyText.isEmpty else { return }
        board.clearContents(); board.setString(model.copyText, forType: .string); model.copied = true; onCopy?()
    }
    func copyImage(to board: NSPasteboard = .general) {
        guard let result = ScreenshotImageRenderer.render(image: image, size: selection.size, document: model.document,
                                                          values: model.completed, original: model.original),
              let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
            model.error = "译文过长或图片暂不可用，请先复制文字。"; return
        }
        board.clearContents(); board.setData(data, forType: .png); model.copied = true; onCopy?()
    }
    private func openWindow() {
        guard let document = model.document else { return }
        let text = document.regions.map { model.completed[$0.id] ?? $0.text }.joined(separator: "\n\n")
        let complete = model.completed.count == document.regions.count
        let callback = onOpenWindow
        close(); callback?(document, text, complete)
    }
    func close() {
        guard !closed else { return }
        closed = true; task?.cancel(); task = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }; spaceObserver = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        panel?.orderOut(nil); toolbar?.orderOut(nil); panel = nil; toolbar = nil
        onClose?()
    }
}
