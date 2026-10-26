// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI

// Run explicitly on a Mac with WeChat and ChatGPT running. Only metadata and
// visibility are asserted; no messages are copied, logged, sent or translated.
@MainActor
func runSelectionCompatibilityTests() async {
    var count = 0
    func check(_ condition: Bool, _ label: String) {
        guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        count += 1; print("PASS: \(label)")
    }
    check(SelectionReader.trusted, "Existing accessibility access is available without requesting a grant")
    let original = NSWorkspace.shared.frontmostApplication
    defer { original?.activate(options: [.activateIgnoringOtherApps]) }
    NSApp.setActivationPolicy(.accessory)
    let defaultsName = "Sonuvi.SelectionCompatibilityFixture." + UUID().uuidString
    let defaults = UserDefaults(suiteName: defaultsName)!
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    defaults.set(OnboardingState.version, forKey: "onboarding.completedVersion")
    let delegate = AppDelegate(); delegate.model.previewMode = true
    delegate.model.mouseLookup = true; delegate.model.clipboardFallback = true; delegate.model.excludedApps = []
    delegate.onboarding = OnboardingState(defaults: defaults)
    delegate.window = FloatingPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let clipboard = NSPasteboard.general.changeCount
    let testFlag = CommandLine.arguments.firstIndex(of: "--selection-compatibility-test")!
    let requested = Array(CommandLine.arguments.dropFirst(testFlag + 1))
    for id in requested.isEmpty ? ["com.tencent.xinWeChat", "com.openai.codex"] : requested {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
            check(false, "Required real application is running: \(id)"); return
        }
        app.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, "Target is foreground: \(id)")
        // A synthetic mouse-up enters the production gesture and AX pipeline.
        // It never changes a chat selection or sends input to the target app.
        let point = NSPoint(x: 300, y: 350)
        delegate.selectionLookup.begin(at: NSPoint(x: 270, y: 350))
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        delegate.onMouseUp(up)
        await delegate.mouseTask?.value
        let probe = await SelectionReader.probeAccessibility(pid: app.processIdentifier, at: point)
        if probe.text == nil {
            check(delegate.bubble?.isVisible != true, "Unverified drag never presents speculative actions: \(id)")
        }
        check(NSPasteboard.general.changeCount == clipboard, "Automatic lookup performs no copy: \(id)")
        delegate.dismissSelectionBubble()
        delegate.model.excludedApps = []; delegate.model.mouseLookup = false
        delegate.selectionLookup.begin(at: NSPoint(x: 270, y: 350))
        delegate.onMouseUp(up)
        await delegate.mouseTask?.value
        check(delegate.bubble?.isVisible != true, "Global selection switch blocks lookup: \(id)")
        delegate.model.mouseLookup = true
        delegate.capture(read: false, expectedPID: -1, anchor: point)
        check(delegate.captureTask == nil, "A stale target cannot start capture: \(id)")
    }
    delegate.bubble?.close()
    print("PASS: \(count) real-app selection compatibility checks")
}

// Companion app has no AX selected text and returns a delayed, long synthetic
// payload on Cmd-C, reproducing the important opaque-client behavior.
@MainActor
func runSelectionCopyTests() async {
    var count = 0
    var cleanup: (() -> Void)?
    func check(_ condition: Bool, _ label: String) {
        guard condition else { cleanup?(); fputs("FAIL: \(label)\n", stderr); exit(1) }
        count += 1; print("PASS: \(label)")
    }
    check(SelectionReader.trusted, "Existing accessibility access is available")
    guard let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: "com.wusir.sonuvi.selectioncopyfixture").first else {
        check(false, "Synthetic copy companion is running"); return
    }
    let original = NSWorkspace.shared.frontmostApplication
    defer { original?.activate(options: [.activateIgnoringOtherApps]) }
    NSApp.setActivationPolicy(.accessory)
    fixture.activate(options: [.activateIgnoringOtherApps])
    try? await Task.sleep(nanoseconds: 800_000_000)
    check(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier, "Synthetic companion owns focus")
    let direct = await SelectionReader.fromAccessibility(pid: fixture.processIdentifier)
    check(direct == nil, "Opaque control does not expose selected text through AX")
    let userClipboardCount = NSPasteboard.general.changeCount
    let pasteboard = NSPasteboard(name: .init("org.sonuvi.selection-copy-fixture"))
    let sentinel = "Sonuvi clipboard fixture " + UUID().uuidString
    let customType = NSPasteboard.PasteboardType("org.sonuvi.synthetic.binary")
    let binary = Data([0, 1, 2, 255])
    pasteboard.clearContents(); pasteboard.setString(sentinel, forType: .string); pasteboard.setData(binary, forType: customType)
    cleanup = { pasteboard.clearContents() }
    defer { cleanup?() }
    let delegate = AppDelegate(); delegate.model.previewMode = true
    var captured: String?; var actionTask: Task<Void, Never>?
    let before = pasteboard.changeCount
    delegate.presentSelectionBubble(point: NSPoint(x: 300, y: 350), translate: {
        delegate.dismissSelectionBubble()
        actionTask = Task { @MainActor in captured = await SelectionReader.capture(pasteboard: pasteboard) }
    }, read: {})
    check(pasteboard.changeCount == before, "Menu display leaves every clipboard format untouched")
    check(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier, "Nonactivating menu preserves opaque app focus")
    // Let SwiftUI install the button views, then deliver native events directly
    // to this test window. The system cursor and target selection stay put.
    try? await Task.sleep(nanoseconds: 250_000_000)
    guard let bubble = delegate.bubble else { check(false, "Selection menu exists"); return }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 22, y: 21), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: bubble.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.postEvent(event, atStart: false)
    }
    try? await Task.sleep(nanoseconds: 150_000_000)
    check(actionTask != nil, "Native click invokes the selection action")
    await actionTask?.value
    let expected = String(repeating: "Sonuvi synthetic selection. 中文 😀\n", count: 3000).trimmingCharacters(in: .whitespacesAndNewlines)
    check(captured == expected, "Clicking the menu reads the full delayed long selection through real Cmd-C")
    check(pasteboard.string(forType: .string) == sentinel && pasteboard.data(forType: customType) == binary,
          "Capture restores original text and custom clipboard data")
    check(delegate.bubble?.isVisible != true, "The action dismisses its selection menu")
    let disabled = await SelectionReader.capture(allowClipboard: false, pasteboard: pasteboard)
    check(disabled == nil && pasteboard.string(forType: .string) == sentinel, "Copy opt-out never synthesizes Cmd-C")
    check(NSPasteboard.general.changeCount == userClipboardCount, "Integration test never modifies the user clipboard")
    delegate.bubble?.close()
    print("PASS: \(count) opaque-control copy integration checks")
}
