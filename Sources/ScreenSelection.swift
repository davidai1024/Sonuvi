// Sonuvi — GPL-3.0. No capture or recognition work in the drag loop.
import AppKit
import QuartzCore
import ScreenCaptureKit

enum CaptureGeometry {
    static func selection(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    static func displayRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

// The pixels and their AppKit coordinate space travel together. Both the
// selection backdrop and OCR crop use this same immutable frame.
struct FrozenCapture {
    let frame: CGRect
    let image: CGImage
    func pixelRect(_ selection: CGRect) -> CGRect {
        let clipped = selection.intersection(frame)
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }
        let sx = CGFloat(image.width) / frame.width
        let sy = CGFloat(image.height) / frame.height
        return CGRect(x: (clipped.minX - frame.minX) * sx,
                      y: (frame.maxY - clipped.maxY) * sy,
                      width: clipped.width * sx, height: clipped.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    func crop(_ selection: CGRect) -> CGImage? {
        let rect = pixelRect(selection)
        return rect.isEmpty ? nil : image.cropping(to: rect)
    }
}

@MainActor
final class ScreenSelection {
    private var panels: [SelectionPanel] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var start: CGPoint?
    private var screenObserver: NSObjectProtocol?

    func select(snapshot: FrozenCapture) async throws -> CGRect? {
        try Task.checkCancellation()
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                for screen in NSScreen.screens {
                    let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false; panel.isOpaque = false
                    panel.backgroundColor = .clear; panel.hasShadow = false
                    panel.level = .screenSaver; panel.hidesOnDeactivate = false
                    panel.animationBehavior = .none
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
                    view.layer?.contents = snapshot.crop(screen.frame)
                    view.layer?.contentsGravity = .resize
                    view.changed = { [weak self] point, ended in self?.drag(point, ended: ended) }
                    view.cancelled = { [weak self] in self?.finish(nil) }
                    panel.contentView = view; panels.append(panel)
                    panel.orderFrontRegardless()
                }
                let active = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first
                active?.makeKey(); active?.makeFirstResponder(active?.contentView)
                NSCursor.crosshair.push()
                screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.finish(nil) }
                }
            }
        }, onCancel: { Task { @MainActor in self.finish(nil) } })
        try Task.checkCancellation()
        return result
    }
    private func drag(_ point: CGPoint, ended: Bool) {
        if start == nil { start = point }
        guard let start else { return }
        let rect = CaptureGeometry.selection(from: start, to: point)
        if ended { finish(rect.width >= 4 && rect.height >= 4 ? rect : nil); return }
        for panel in panels {
            (panel.contentView as? SelectionView)?.update(rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY))
        }
    }
    private func finish(_ rect: CGRect?) {
        guard let continuation else { return }
        self.continuation = nil; start = nil
        for panel in panels { panel.orderOut(nil) }; panels.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        NSCursor.pop()
        continuation.resume(returning: rect)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    var changed: ((CGPoint, Bool) -> Void)?
    var cancelled: (() -> Void)?
    private let shade = CAShapeLayer()
    private let border = CAShapeLayer()
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shade.fillColor = NSColor.black.withAlphaComponent(0.24).cgColor
        shade.fillRule = .evenOdd
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = NSColor.white.cgColor; border.lineWidth = 1
        layer?.addSublayer(shade); layer?.addSublayer(border)
        let hint = NSTextField(labelWithString: L10n.text("拖动选择文字区域 · Esc 取消"))
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white; hint.alignment = .center
        hint.frame = NSRect(x: 16, y: frame.height - 72, width: frame.width - 32, height: 24)
        hint.autoresizingMask = [.width, .minYMargin]
        addSubview(hint)
        update(.zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    func update(_ selection: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let path = CGMutablePath(); path.addRect(bounds)
        if !selection.isEmpty { path.addRect(selection) }
        shade.path = path
        border.path = selection.isEmpty ? nil : CGPath(rect: selection, transform: nil)
        CATransaction.commit()
    }
    private func point(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation }
    override func mouseDown(with event: NSEvent) { changed?(point(event), false) }
    override func mouseDragged(with event: NSEvent) { changed?(point(event), false) }
    override func mouseUp(with event: NSEvent) { changed?(point(event), true) }
    override func rightMouseDown(with event: NSEvent) { cancelled?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { cancelled?() } }
}
