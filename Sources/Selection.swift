// Sonuvi — GPL-3.0.
import AppKit
import ApplicationServices
import Carbon

@MainActor
enum SelectionReader {
    static var trusted: Bool { AXIsProcessTrusted() }
    // Explicit user action only. Register with TCC once; subsequent clicks
    // open Settings directly. Polling never requests permission.
    static func openPermissionSettings() {
        guard !trusted else { return }
        if UserDefaults.standard.bool(forKey: "accessibilityPermissionRequested") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else {
            UserDefaults.standard.set(true, forKey: "accessibilityPermissionRequested")
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    }
    // Only called once after the user explicitly repairs and relaunches.
    static func registerAfterRepair() {
        UserDefaults.standard.set(true, forKey: "accessibilityPermissionRequested")
        UserDefaults.standard.synchronize()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    static func fromAccessibility() -> String? {
        guard trusted, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return selectedText(pid: front.processIdentifier)
    }
    // AX IPC runs off the UI thread. Cancel queued work when a newer gesture
    // arrives, so unsupported controls cannot create an ever-growing backlog.
    private static let lookupQueue = DispatchQueue(label: "Sonuvi.selection", qos: .userInitiated)
    // Accessed only on lookupQueue, for explicit per-process accessibility opt-ins.
    nonisolated(unsafe) private static var manualAccessibilityAttempts: [pid_t: TimeInterval] = [:]
    static func fromAccessibility(pid: pid_t, at point: NSPoint? = nil) async -> String? {
        guard trusted, !Task.isCancelled else { return nil }
        let axPoint = point.map { CGPoint(x: $0.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - $0.y) }
        let profile = accessibilityProfile(pid: pid)
        let ticket = SelectionReadTicket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lookupQueue.async {
                    guard !ticket.cancelled else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: selectedText(pid: pid, at: axPoint, profile: profile, isCancelled: { ticket.cancelled }))
                }
            }
        } onCancel: { ticket.cancel() }
    }
    static func accessibilityProfile(pid: pid_t) -> SelectionAccessibilityProfile {
        let app = NSRunningApplication(processIdentifier: pid)
        let electron = app?.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        return .resolve(bundleID: app?.bundleIdentifier, electron: electron)
    }
    static func prepareAccessibility(pid: pid_t) {
        guard trusted, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let profile = accessibilityProfile(pid: pid)
        guard profile.activationAttribute != nil else { return }
        lookupQueue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.08)
            activateAccessibility(app: app, pid: pid, profile: profile)
        }
    }
    nonisolated private static func activateAccessibility(app: AXUIElement, pid: pid_t, profile: SelectionAccessibilityProfile) {
        guard AXIsProcessTrusted(), let attribute = profile.activationAttribute else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (manualAccessibilityAttempts[pid] ?? -100) > 30 else { return }
        if manualAccessibilityAttempts.count > 64 { manualAccessibilityAttempts.removeAll() }
        manualAccessibilityAttempts[pid] = now
        // Per-process opt-in documented by Electron / Chromium source. This
        // neither enables VoiceOver nor changes a system-wide preference.
        AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
    }
    nonisolated private static func selectedText(pid: pid_t, at point: CGPoint? = nil,
        profile: SelectionAccessibilityProfile = .standard, isCancelled: () -> Bool = { false }) -> String? {
        guard AXIsProcessTrusted(), !isCancelled(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.24
        func valid() -> Bool { !isCancelled() && ProcessInfo.processInfo.systemUptime < deadline }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        activateAccessibility(app: app, pid: pid, profile: profile)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard valid() else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.08)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let focused = element(attribute(app, kAXFocusedUIElementAttribute))
        if let focused, attribute(focused, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return nil }
        var hit: AXUIElement?
        if let point, valid() {
            AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
            if let found = hit {
                var hitPID: pid_t = 0
                if AXUIElementGetPid(found, &hitPID) != .success || hitPID != pid { hit = nil }
            }
        }
        return SelectionNodeSearch.resolve(hit: hit, focused: focused, parent: {
            element(attribute($0, kAXParentAttribute))
        }, read: { node in
            if attribute(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return .protected }
            if let text = SelectionText.usable(attribute(node, kAXSelectedTextAttribute) as? String) { return .text(text) }
            // Chromium/WebKit document selections can span several text nodes.
            // Use the selected marker only; never read the full document value.
            if let marker = attribute(node, "AXSelectedTextMarkerRange"), valid() {
                var selected: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(node, "AXStringForTextMarkerRange" as CFString, marker, &selected) == .success,
                   let text = SelectionText.usable(selected as? String) { return .text(text) }
            }
            guard let rangeValue = attribute(node, kAXSelectedTextRangeAttribute),
                  CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .empty }
            var range = CFRange()
            guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
                  range.location >= 0, range.length > 0, range.length <= 6000 else { return .empty }
            var value: CFTypeRef?
            if valid(), AXUIElementCopyParameterizedAttributeValue(node, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value) == .success,
               let text = SelectionText.usable(value as? String) { return .text(text) }
            guard let text = attribute(node, kAXValueAttribute) as? String,
                  let selected = SelectionText.substring(text, location: range.location, length: range.length) else { return .empty }
            return .text(selected)
        }, isValid: valid, maximumDepth: profile == .chromium ? 8 : 4)
    }
    // AX selection bounds use a top-left screen origin; AppKit uses bottom-left.
    static func selectionAnchor() -> NSPoint? {
        guard trusted, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        var range: CFTypeRef?; var bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), !rect.isEmpty,
              let primary = NSScreen.screens.first else { return nil }
        return NSPoint(x: rect.minX, y: primary.frame.maxY - rect.maxY)
    }
    static func selectionAnchor(pid: pid_t) async -> NSPoint? {
        guard trusted, !Task.isCancelled else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return await withCheckedContinuation { continuation in
            lookupQueue.async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.08)
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { continuation.resume(returning: nil); return }
                let element = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.08)
                var subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                guard subrole as? String != kAXSecureTextFieldSubrole else { continuation.resume(returning: nil); return }
                var range: CFTypeRef?; var bounds: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
                      let range, CFGetTypeID(range) == AXValueGetTypeID() else { continuation.resume(returning: nil); return }
                var selection = CFRange()
                guard AXValueGetValue(range as! AXValue, .cfRange, &selection), selection.length > 0,
                      AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
                      let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { continuation.resume(returning: nil); return }
                var rect = CGRect.zero
                guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), !rect.isEmpty else { continuation.resume(returning: nil); return }
                continuation.resume(returning: NSPoint(x: rect.minX, y: primaryHeight - rect.maxY))
            }
        }
    }
    // Clipboard fallback runs only after an explicit shortcut. Restore all data
    // types if no newer clipboard write occurred; never replace a newer user copy.
    static func capture(allowClipboard: Bool = true) async -> String? {
        guard !Task.isCancelled, trusted, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = front.processIdentifier
        // Keyboard commands follow focus, not an unrelated mouse position.
        if let text = await fromAccessibility(pid: pid) {
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            return text
        }
        guard allowClipboard, !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused {
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == kAXSecureTextFieldSubrole { return nil }
        }
        let pasteboard = NSPasteboard.general
        let originalCount = pasteboard.changeCount
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        }
        // Large clipboards are left untouched. OCR/manual input remains available.
        if saved.reduce(0, { $0 + $1.values.reduce(0, { $0 + $1.count }) }) > 16_000_000 { return nil }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.postToPid(pid); up?.postToPid(pid)
        for _ in 0..<12 {
            // Finish restoration even if a newer selection cancels this task.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { continuation.resume() }
            }
            if pasteboard.changeCount != originalCount { break }
        }
        guard pasteboard.changeCount != originalCount else { return nil }
        let afterCopy = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        // Do not yield between change-count check and restoration.
        if pasteboard.changeCount == afterCopy {
            pasteboard.clearContents()
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class GlobalShortcuts {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onTranslate: (() -> Void)?
    var onRead: (() -> Void)?
    var onOCR: (() -> Void)?
    private var current: [ShortcutSpec] = []
    var installed: [ShortcutSpec] { current }
    func suspend() { for ref in refs { UnregisterEventHotKey(ref) }; refs.removeAll() }
    func resume() -> Bool {
        guard refs.isEmpty else { return refs.count == 3 }
        guard !current.isEmpty else { return false }
        return register(current)
    }
    func install(_ specs: [ShortcutSpec] = [.translate, .read, .ocr]) -> Bool {
        if handler != nil { return configure(specs) }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4D555345, (1...3).contains(identifier.id) else { return OSStatus(eventNotHandledErr) }
            let instance = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            DispatchQueue.main.async { if id == 1 { instance.onTranslate?() } else if id == 2 { instance.onRead?() } else if id == 3 { instance.onOCR?() } }
            return noErr
        }, 1, &event, ptr, &handler)
        guard status == noErr else { return false }
        return configure(specs)
    }
    private func register(_ specs: [ShortcutSpec]) -> Bool {
        for (offset, spec) in specs.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: 0x4D555345, id: UInt32(offset + 1)), GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { for ref in refs { UnregisterEventHotKey(ref) }; refs.removeAll(); return false }
            refs.append(ref)
        }
        return true
    }
    private func configure(_ specs: [ShortcutSpec]) -> Bool {
        let old = current
        for ref in refs { UnregisterEventHotKey(ref) }; refs.removeAll()
        if register(specs) { current = specs; return true }
        current = !old.isEmpty && register(old) ? old : []
        return false
    }
}
