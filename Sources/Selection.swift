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
    static func fromAccessibility() -> String? {
        guard trusted, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return nil
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
    // Clipboard fallback runs only after an explicit shortcut. Restore all data
    // types if no newer clipboard write occurred; never replace a newer user copy.
    static func capture(allowClipboard: Bool = true) async -> String? {
        if let text = fromAccessibility() { return text }
        guard allowClipboard, !Task.isCancelled, trusted, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = front.processIdentifier
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
