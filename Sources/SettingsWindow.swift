// Sonuvi — GPL-3.0.
import AppKit

/// Keep AppKit's real controls (including hover/zoom behavior) and only inset
/// their placement to match the reference's floating sidebar chrome.
final class SettingsWindow: NSWindow {
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        guard !styleMask.contains(.fullScreen), let frameView = contentView?.superview else { return }
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = standardWindowButton(kind), let parent = button.superview else { continue }
            let center = NSPoint(x: 26 + CGFloat(index) * 23, y: frameView.bounds.height - 26)
            let local = parent.convert(center, from: frameView)
            button.setFrameOrigin(NSPoint(x: local.x - button.frame.width / 2, y: local.y - button.frame.height / 2))
        }
    }
}
