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

/// Keychain dialogs may change application activation. Restore only the window
/// that initiated access, including on cancel; never create a new settings page.
@MainActor
final class CredentialWindowPresentation {
    private weak var origin: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var explicitlyClosed = false
    private(set) var isActive = false
    func begin(windows: [NSWindow?]) {
        origin = windows.compactMap { $0 }.first { $0.isKeyWindow && $0.isVisible }
            ?? windows.compactMap { $0 }.first { $0.isVisible }
        explicitlyClosed = false; isActive = true
        if let origin {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: origin, queue: .main) { [weak self] _ in
                self?.explicitlyClosed = true
            }
        }
    }
    func finish() {
        defer {
            isActive = false; origin = nil
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
        }
        guard let origin, !explicitlyClosed else { return }
        NSApp.activate(ignoringOtherApps: true)
        origin.makeKeyAndOrderFront(nil)
    }
}
