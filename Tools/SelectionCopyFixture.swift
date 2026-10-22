// Sonuvi — GPL-3.0. Synthetic opaque control; no personal content or networking.
import AppKit

let payload = String(repeating: "Sonuvi synthetic selection. 中文 😀\n", count: 3000)
final class OpaqueSelection: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        ("Sonuvi 取词兼容测试\n\n仅含固定测试文字，不发送网络请求。" as NSString).draw(
            in: bounds.insetBy(dx: 24, dy: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor])
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.keyCode == 8, event.modifierFlags.contains(.command) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let pasteboard = NSPasteboard(name: .init("org.sonuvi.selection-copy-fixture"))
            pasteboard.clearContents(); pasteboard.setString(payload, forType: .string)
        }
        return true
    }
}
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 450, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Sonuvi synthetic selection fixture"
        let control = OpaqueSelection(frame: NSRect(x: 0, y: 0, width: 450, height: 200))
        window.contentView = control; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(control)
        NSApp.activate(ignoringOtherApps: true)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = FixtureDelegate(); application.delegate = delegate; application.run()
