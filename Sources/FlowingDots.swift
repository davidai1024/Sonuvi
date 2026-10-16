// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI

/// Decorative light over a fixed grid. Progress is stable; only luminance moves.
struct FlowingDots: NSViewRepresentable {
    var progress: Double
    var compact = false
    var animate = true
    var audioLevels: [Double]?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> DotFieldView { DotFieldView() }
    func updateNSView(_ view: DotFieldView, context: Context) {
        view.audioLevels = audioLevels
        view.progress = min(1, max(0, progress))
        view.compact = compact; view.dark = scheme == .dark
        view.animationEnabled = animate && !reduceMotion
        view.updateAnimation(); view.needsDisplay = true
    }
    static func dismantleNSView(_ view: DotFieldView, coordinator: ()) { view.stopAnimation() }
}

final class DotFieldView: NSView {
    var audioLevels: [Double]?
    var progress = 0.0
    var compact = false
    var dark = false
    var animationEnabled = true
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var phase = 0.0
    private var previousTick = ProcessInfo.processInfo.systemUptime
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }; observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateAnimation() })
            }
            observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.updateAnimation() })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateAnimation() })
        }
        updateAnimation()
    }
    func stopAnimation() { timer?.invalidate(); timer = nil }
    func updateAnimation() {
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        let allowed = animationEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
        guard visible && allowed else { stopAnimation(); needsDisplay = true; return }
        guard timer == nil else { return }
        previousTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.window?.isVisible == true, self.window?.occlusionState.contains(.visible) == true, !self.isHiddenOrHasHiddenAncestor,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { self.stopAnimation(); return }
            let now = ProcessInfo.processInfo.systemUptime
            self.phase += min(0.1, max(0, now - self.previousTick)); self.previousTick = now
            if !self.visibleRect.isEmpty { self.needsDisplay = true }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        // NSMenu tracks in its own run-loop mode. Keep the same motion there.
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    override func layout() { super.layout(); updateAnimation() }
    deinit {
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0 else { return }
        let columns = max(12, Int(bounds.width / (compact ? 6.1 : 7.0)))
        let rows = compact ? 5 : 7
        let stepX = bounds.width / CGFloat(columns)
        let stepY = bounds.height / CGFloat(rows)
        let radius = min(compact ? 1.35 : 1.65, min(stepX, stepY) * 0.27)
        let tint = dark ? NSColor(srgbRed: 0.29, green: 0.83, blue: 0.46, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.59, blue: 0.28, alpha: 1)
        let inactive = NSColor.labelColor.withAlphaComponent(dark ? 0.11 : 0.075)
        let paths = (0..<12).map { _ in CGMutablePath() }
        let base = CGMutablePath()
        let t = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : phase
        for row in 0..<rows { for column in 0..<columns {
            let x = (Double(column) + 0.5) / Double(columns)
            let y = (Double(row) + 0.5) / Double(rows)
            let rect = CGRect(x: (CGFloat(column) + 0.5) * stepX - radius, y: (CGFloat(row) + 0.5) * stepY - radius, width: radius * 2, height: radius * 2)
            base.addEllipse(in: rect)
            let coverage = progress <= 0 ? 0 : min(1, max(0, (progress - x) * 8 + 0.55))
            let ribbon = 0.5 + 0.5 * sin(x * 10.0 - t * 1.4 + sin(y * 5.2 + t * 0.6) * 1.8)
            let shimmer = 0.88 + 0.12 * sin(Double(column) * 0.77 + Double(row) * 1.3 - t * 1.9)
            let intensity: Double
            if let levels = audioLevels, !levels.isEmpty {
                let level = levels[min(levels.count - 1, Int(x * Double(levels.count)))]
                let distance = abs(y - 0.5) * 2
                intensity = level > 0.02 && distance <= max(0.18, level) ? min(1, 0.3 + level * 0.7) : 0
            } else { intensity = coverage * (0.46 + 0.54 * ribbon) * shimmer }
            if intensity > 0.025 { paths[min(11, Int(intensity * 11))].addEllipse(in: rect) }
        } }
        context.setFillColor(inactive.cgColor); context.addPath(base); context.fillPath()
        for (index, path) in paths.enumerated() {
            let alpha = 0.18 + CGFloat(index) / 11 * 0.82
            context.saveGState()
            if index >= 8 { context.setShadow(offset: .zero, blur: compact ? 2 : 3, color: tint.withAlphaComponent(dark ? 0.40 : 0.16).cgColor) }
            context.setFillColor(tint.withAlphaComponent(alpha).cgColor)
            context.addPath(path); context.fillPath(); context.restoreGState()
        }
    }
}

/// A closed menu explicitly pauses its custom view, even if AppKit retains it.
final class MenuMotion: ObservableObject { @Published var active = false }

enum UsageMilestone {
    static func next(after words: Int) -> Int {
        let steps = [100, 500, 1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 500_000, 1_000_000]
        return steps.first(where: { $0 > words }) ?? max(1_000_000, (words / 1_000_000 + 1) * 1_000_000)
    }
}
