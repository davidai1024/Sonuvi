// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI

@MainActor
final class ReadingBarController {
    var anchor: NSPoint?
    private var panel: BubblePanel?
    private var dismissal: Task<Void, Never>?

    func update(_ message: String?, isActive: Bool, meter: SpeechMeter, stop: @escaping () -> Void) {
        dismissal?.cancel()
        guard let message else { panel?.orderOut(nil); anchor = nil; return }
        if panel == nil {
            let window = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: 194, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.level = .floating; window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            panel = window
        }
        guard let panel else { return }
        let wasVisible = panel.isVisible
        let width: CGFloat = isActive ? 252 : 320
        panel.setContentSize(NSSize(width: width, height: 40))
        panel.contentView = NSHostingView(rootView: ReadingBar(message: message, isActive: isActive, meter: meter, stop: stop))
        if !wasVisible {
            let point = anchor ?? NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                panel.setFrameOrigin(WindowGeometry.origin(near: point, size: panel.frame.size, visible: screen.visibleFrame))
            }
        }
        panel.orderFrontRegardless()
        if !isActive {
            dismissal = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                stop(); self?.panel?.orderOut(nil)
            }
        }
    }
}

private struct ReadingBar: View {
    let message: String
    let isActive: Bool
    let meter: SpeechMeter
    let stop: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            ReadingDragHandle().frame(width: 24, height: 32).help(L10n.text("拖动朗读条"))
            if isActive { SpeechDots(meter: meter) }
            else { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary) }
            LText(message).font(.system(size: 12)).lineLimit(1).truncationMode(.tail).help(L10n.text(message))
            Spacer(minLength: 0)
            Button(action: stop) {
                Image(systemName: isActive ? "stop.fill" : "xmark")
                    .font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 30).contentShape(Rectangle())
            }.buttonStyle(MuseHoverStyle(radius: 7)).help(L10n.text(isActive ? "停止朗读" : "关闭"))
                .accessibilityLabel(L10n.text(isActive ? "停止朗读" : "关闭朗读提示"))
        }.padding(.leading, 4).padding(.trailing, 5).frame(height: 40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ReadingDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ nsView: Handle, context: Context) { nsView.setAccessibilityLabel(L10n.text("拖动朗读条")) }
    final class Handle: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(L10n.text("拖动朗读条"))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push(); defer { NSCursor.pop() }
            window?.performDrag(with: event)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setFill()
            for x in [-3.0, 3.0] { for y in [-5.0, 0.0, 5.0] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1, y: bounds.midY + y - 1, width: 2, height: 2)).fill()
            } }
        }
    }
}
