// Sonuvi — GPL-3.0. Password entry with ordinary, dismissible macOS focus.
import AppKit
import SwiftUI

struct APIKeyField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var bordered = true
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}

    final class Field: NSSecureTextField {
        var cancelled = false
        private var monitor: Any?
        private var observer: NSObjectProtocol?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        func beginEditingSession() {
            endEditingSession()
            cancelled = false
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.currentEditor() != nil else { return event }
                if event.type == .leftMouseDown {
                    if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        window.makeFirstResponder(nil)
                    }
                    return event // The original click still reaches its control.
                }
                if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
                    self.cancelled = event.keyCode == 53
                    window.makeFirstResponder(nil)
                    return nil // Finish editing without advancing onboarding.
                }
                return event
            }
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.window?.makeFirstResponder(nil); self.endEditingSession()
                }
            }
        }
        func endEditingSession() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endEditingSession() }
            super.viewWillMove(toWindow: newWindow)
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: APIKeyField
        init(_ parent: APIKeyField) { self.parent = parent }
        func controlTextDidBeginEditing(_ obj: Notification) { (obj.object as? Field)?.beginEditingSession() }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? Field else { return }; parent.text = field.stringValue
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? Field else { return }
            parent.text = field.stringValue; field.endEditingSession()
            if field.cancelled { parent.onCancel() } else { parent.onCommit() }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
                (control as? Field)?.cancelled = selector == #selector(NSResponder.cancelOperation(_:))
                control.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator; field.font = .systemFont(ofSize: 13)
        field.isBezeled = bordered; field.bezelStyle = .roundedBezel
        field.drawsBackground = bordered; field.focusRingType = bordered ? .default : .none
        field.setAccessibilityLabel(L10n.text("DeepSeek API Key"))
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder; field.isEnabled = context.environment.isEnabled
        if field.stringValue != text { field.stringValue = text }
        // Never makeFirstResponder here: SwiftUI updates must not recapture focus.
    }
}
