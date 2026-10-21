// Sonuvi — GPL-3.0.
import AppKit

@MainActor
func runSelectionTests() async {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1
    }
    var state = SelectionLookupState()
    let start = NSPoint(x: -400, y: 1200), end = NSPoint(x: -100, y: 1200)
    check(state.finish(at: end, clicks: 2, shift: false, pid: 10) == nil, "Stray mouse-up cannot resurrect a consumed selection")
    state.begin(at: start)
    let first = state.finish(at: end, clicks: 1, shift: false, pid: 10)!
    check(state.accepts(first, frontPID: 10), "Drag works on a negative-origin upper display")
    check(!state.accepts(first, frontPID: 20), "Changing foreground rejects the old read")
    state.activated(pid: 10)
    check(state.accepts(first, frontPID: 10), "Late activation for the selected app does not cancel its lookup")
    check(state.finish(at: end, clicks: 2, shift: false, pid: 10) == nil, "Duplicate mouse-up is ignored")
    state.invalidate()
    check(!state.accepts(first, frontPID: 10), "Bubble action invalidates pending results")
    state.begin(at: start)
    let second = state.finish(at: end, clicks: 1, shift: false, pid: 10)!
    check(state.accepts(second, frontPID: 10), "A fresh drag immediately after an action is allowed")
    check(!state.accepts(first, frontPID: 10), "New gesture supersedes older results")
    state.activated(pid: 20)
    check(!state.accepts(second, frontPID: 10), "Switching apps invalidates outstanding lookup")
    state.begin(at: start); state.activated(pid: 10)
    check(state.finish(at: end, clicks: 1, shift: false, pid: 10) != nil, "Activation during a drag preserves the press")
    state.begin(at: start)
    check(state.finish(at: start, clicks: 1, shift: false, pid: 10) == nil, "Ordinary click does not trigger lookup")
    state.begin(at: start)
    check(state.finish(at: start, clicks: 2, shift: false, pid: 10) != nil, "Double-click selection triggers lookup")
    state.begin(at: start)
    check(state.finish(at: start, clicks: 1, shift: true, pid: 10) != nil, "Shift-click selection triggers lookup")
    state.begin(at: start); state.invalidate()
    check(state.finish(at: end, clicks: 1, shift: false, pid: 10) == nil, "Scroll/cancel/local click resets the gesture")

    let keyboardRequest = state.keyboard(pid: 10)
    check(state.accepts(keyboardRequest, frontPID: 10), "Keyboard selection does not require a mouse-down gesture")
    let nextKeyboardRequest = state.keyboard(pid: 20)
    check(!state.accepts(nextKeyboardRequest, frontPID: 10), "Keyboard request cannot read from a different foreground app")
    check(!state.accepts(keyboardRequest, frontPID: 10), "A newer keyboard request cancels the older selection")
    check(KeyboardSelectionAction.resolve(keyCode: 0, flags: .command) == .select, "Command-A triggers a focused selection lookup")
    check(KeyboardSelectionAction.resolve(keyCode: 124, flags: [.shift, .option]) == .select, "Option-Shift arrow selection triggers lookup")
    check(KeyboardSelectionAction.resolve(keyCode: 125, flags: [.shift, .command]) == .select, "Command-Shift arrow selection triggers lookup")
    check(KeyboardSelectionAction.resolve(keyCode: 96, flags: []) == .inspect, "Third-party function-key selection can be inspected")
    check(KeyboardSelectionAction.resolve(keyCode: 40, flags: [.control, .option]) == .inspect, "Custom modified selection hotkeys can be inspected")
    check(KeyboardSelectionAction.resolve(keyCode: 8, flags: .command) == .dismiss, "Copy does not resurrect the old selection popup")
    check(KeyboardSelectionAction.resolve(keyCode: 9, flags: .command) == .dismiss, "Paste does not display stale selection")
    check(KeyboardSelectionAction.resolve(keyCode: 53, flags: []) == .dismiss, "Escape dismisses keyboard selection")
    check(KeyboardSelectionAction.resolve(keyCode: 40, flags: []) == .dismiss, "Ordinary typing never probes the selected control")
    check(KeyboardSelectionAction.resolve(keyCode: 40, flags: .shift) == .dismiss, "Typing uppercase letters does not trigger IME selection popups")
    check(KeyboardSelectionAction.resolve(keyCode: 49, flags: .control) == .dismiss, "Switching input methods does not inspect a composing selection")
    check(KeyboardSelectionAction.resolve(keyCode: 56, flags: .shift) == .ignore, "Modifier key releases alone never trigger selection")
    check(KeyboardSelectionAction.resolve(keyCode: 17, flags: [.option, .shift], shortcuts: [.translate]) == .dismiss, "Sonuvi's own translate shortcut cannot reopen the popup")

    check(SelectionText.substring("A😀English中文", location: 3, length: 7) == "English", "AX ranges use UTF-16 offsets")
    check(SelectionText.substring("abc", location: -1, length: 1) == nil, "Negative AX offset is rejected")
    check(SelectionText.substring("abc", location: 1, length: Int.max) == nil, "Overflowing AX range is rejected")
    check(SelectionText.substring("abc", location: 0, length: 0) == nil, "Caret is not a text selection")
    check(SelectionText.substring("abc", location: 3, length: 1) == nil, "Stale range cannot read outside the control")
    check(SelectionText.usable(" \n ") == nil, "Blank selection is ignored")

    let parents = [1: 2, 2: 3, 4: 5]
    let parent: (Int) -> Int? = { parents[$0] }
    let hitOnly = SelectionNodeSearch.resolve(hit: 1, focused: nil, parent: parent,
        read: { $0 == 1 ? .text("Selected message") : .empty })
    check(hitOnly == "Selected message", "Selection does not require an AX focused control")
    let web = SelectionNodeSearch.resolve(hit: 1, focused: 4, parent: parent,
        read: { $0 == 3 ? .text("Web document selection") : .empty })
    check(web == "Web document selection", "Selection on an ancestor web area is found")
    let focusedFallback = SelectionNodeSearch.resolve(hit: 1, focused: 4, parent: parent,
        read: { $0 == 4 ? .text("Editor selection") : .empty })
    check(focusedFallback == "Editor selection", "Focused editor remains a fallback outside glyph bounds")
    let priority = SelectionNodeSearch.resolve(hit: 1, focused: 4, parent: parent,
        read: { .text($0 == 1 ? "New selection" : "Old selection") })
    check(priority == "New selection", "Pointer selection takes priority over stale focused selection")
    let protected = SelectionNodeSearch.resolve(hit: 1, focused: 4, parent: parent,
        read: { $0 == 1 ? .protected : .text("Must not read") })
    check(protected == nil, "Secure control stops all fallback reads")
    var nodeReads = 0
    let cyclic = SelectionNodeSearch.resolve(hit: 1, focused: 1, parent: { _ in 1 },
        read: { _ in nodeReads += 1; return .empty })
    check(cyclic == nil && nodeReads == 1, "Repeated and cyclic AX nodes cannot loop")
    nodeReads = 0
    _ = SelectionNodeSearch.resolve(hit: 1, focused: nil, parent: { $0 + 1 },
        read: { _ in nodeReads += 1; return .empty })
    check(nodeReads == 4, "Ancestor search has a strict depth limit")
    nodeReads = 0
    let timedOut = SelectionNodeSearch.resolve(hit: 1, focused: nil, parent: parent,
        read: { _ in nodeReads += 1; return .empty }, isValid: { false })
    check(timedOut == nil && nodeReads == 0, "Expired or cancelled probes do no IPC")
    let ticket = SelectionReadTicket()
    check(!ticket.cancelled, "New queued read starts live")
    ticket.cancel()
    check(ticket.cancelled, "Superseded queued read is cancelled across executors")

    check(SelectionAccessibilityProfile.resolve(bundleID: "com.google.Chrome", electron: false) == .chromium, "Chrome receives browser-specific accessibility activation")
    check(SelectionAccessibilityProfile.resolve(bundleID: "com.microsoft.edgemac", electron: false) == .chromium, "Known Chromium browsers share compatibility handling")
    check(SelectionAccessibilityProfile.resolve(bundleID: "unrelated.app", electron: false).activationAttribute == nil, "Unknown native apps are not force-enabled")
    check(SelectionAccessibilityProfile.resolve(bundleID: "test.electron", electron: true).activationAttribute == "AXManualAccessibility", "Electron retains its own documented opt-in")
    check(SelectionAccessibilityProfile.chromium.activationAttribute == "AXEnhancedUserInterface", "Chrome uses its supported opt-in rather than Electron's attribute")
    nodeReads = 0
    let nestedWeb = SelectionNodeSearch.resolve(hit: 1, focused: nil, parent: { $0 + 1 }, read: { node in
        nodeReads += 1; return node == 7 ? .text("Selected across web nodes") : .empty
    }, maximumDepth: 8)
    check(nestedWeb == "Selected across web nodes" && nodeReads == 7, "Bounded browser ancestors reach deeply nested page selections")
    nodeReads = 0
    _ = SelectionNodeSearch.resolve(hit: 1, focused: nil, parent: { $0 + 1 }, read: { _ in nodeReads += 1; return .empty }, maximumDepth: 10000)
    check(nodeReads == 8, "Browser probing never expands into an unbounded tree scan")
    var elapsed: UInt64 = 0
    let warmingBrowser = await SelectionLookup.resolve(read: { elapsed >= 2_000_000_000 ? "Ready browser selection" : nil }, isValid: { true }, delays: SelectionAccessibilityProfile.chromium.retryDelays, wait: { elapsed += $0 })
    check(warmingBrowser == "Ready browser selection" && elapsed < 3_000_000_000, "First Chrome selection survives the two-second activation delay")
    var reads = 0
    let noWait: (UInt64) async throws -> Void = { _ in }
    let delayed = await SelectionLookup.resolve(read: {
        reads += 1; return reads < 3 ? nil : "Delayed browser selection"
    }, isValid: { true }, wait: noWait)
    check(delayed == "Delayed browser selection" && reads == 3, "Delayed selection succeeds on a later AX read")
    reads = 0
    let immediate = await SelectionLookup.resolve(read: { reads += 1; return "Ready" }, isValid: { true }, wait: noWait)
    check(immediate == "Ready" && reads == 1, "Ready selection does not wait for further retries")
    reads = 0
    let unsupported = await SelectionLookup.resolve(read: { reads += 1; return nil }, isValid: { true }, wait: noWait)
    check(unsupported == nil && reads == 3, "Unsupported app stops after a bounded number of reads")
    reads = 0
    let blocked = await SelectionLookup.resolve(read: { reads += 1; return "Never read" }, isValid: { false }, wait: noWait)
    check(blocked == nil && reads == 0, "Disabled/excluded/OCR state prevents all reads")
    var valid = true
    let stale = await SelectionLookup.resolve(read: { valid = false; return "Old selection" }, isValid: { valid }, wait: noWait)
    check(stale == nil, "Change during AX IPC cannot display stale text")
    state.begin(at: start)
    let current = state.finish(at: end, clicks: 1, shift: false, pid: 10)!
    let consumed = await SelectionLookup.resolve(read: { state.invalidate(); return "Consumed" }, isValid: { state.accepts(current, frontPID: 10) }, wait: noWait)
    check(consumed == nil, "Clicking translate/read during retrieval never reopens the bubble")
    let cancelledWait = await SelectionLookup.resolve(read: { "Never" }, isValid: { true }, wait: { _ in throw CancellationError() })
    check(cancelledWait == nil, "Cancelled delay ends lookup")
    let cancellation = Task { @MainActor in
        await SelectionLookup.resolve(read: { "Never" }, isValid: { true }, wait: noWait)
    }
    cancellation.cancel()
    let cancelled = await cancellation.value
    check(cancelled == nil, "Cancelled task never presents a selection")
    // A deferred accessibility response must not block the main actor.
    var heartbeat = false
    let responsive = await SelectionLookup.resolve(read: {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { heartbeat = true; continuation.resume(returning: "Responsive") }
        }
    }, isValid: { true }, wait: noWait)
    check(responsive == "Responsive" && heartbeat, "Selection lookup leaves the UI executor available")
    let fixtureName = "Sonuvi.KeyboardSelectionFixture." + UUID().uuidString
    let defaults = UserDefaults(suiteName: fixtureName)!
    defer { defaults.removePersistentDomain(forName: fixtureName) }
    defaults.set(OnboardingState.version, forKey: "onboarding.completedVersion")
    let delegate = AppDelegate(); delegate.model.previewMode = true
    delegate.model.translateShortcut = .translate; delegate.model.readShortcut = .read; delegate.model.ocrShortcut = .ocr
    delegate.model.mouseLookup = true; delegate.onboarding = OnboardingState(defaults: defaults)
    let fixture = FloatingPanel(contentRect: NSRect(x: 40, y: 40, width: 440, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
    fixture.isReleasedWhenClosed = false
    let editor = NSTextView(frame: NSRect(x: 12, y: 12, width: 416, height: 156))
    editor.string = "A synthetic keyboard selection."; editor.isSelectable = true
    fixture.contentView = editor; delegate.window = fixture
    NSApp.setActivationPolicy(.accessory)
    fixture.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    try? await Task.sleep(nanoseconds: 150_000_000)
    fixture.makeKey(); fixture.makeFirstResponder(editor)
    @MainActor func keyboard(_ code: UInt16, _ flags: NSEvent.ModifierFlags) async {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        delegate.onSelectionKeyDown(down, local: true)
        delegate.onSelectionKeyUp(up, local: true)
        try? await Task.sleep(nanoseconds: 180_000_000)
    }
    editor.selectAll(nil)
    check(fixture.isKeyWindow && fixture.firstResponder === editor, "Keyboard fixture has the same focused-editor state as an active Sonuvi window")
    await keyboard(0, .command)
    check(delegate.bubble?.isVisible == true && delegate.lastSelection?.text == editor.string, "Command-A in a real text view displays the popup without any mouse gesture")
    await keyboard(8, .command)
    check(delegate.bubble?.isVisible != true, "Copy dismisses the popup and does not reopen it")
    await keyboard(96, [])
    check(delegate.bubble?.isVisible != true, "Unchanged selection after another key does not resurrect the popup")
    editor.setSelectedRange(NSRange(location: 2, length: 9))
    await keyboard(124, [.option, .shift])
    check(delegate.bubble?.isVisible == true && delegate.lastSelection?.text == "synthetic", "Shift-arrow selection reads the focused editor rather than the cursor position")
    delegate.dismissSelectionBubble(); delegate.bubble?.close(); fixture.close()
    print("PASS: \(count) selection regression checks")
}

