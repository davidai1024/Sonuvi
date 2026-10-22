// Sonuvi — GPL-3.0.
import AppKit

final class SelectionReadTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

// One request per real gesture. Consuming/dismissing a selection invalidates all
// outstanding AX reads, without blocking a different selection for half a second.
struct SelectionLookupState {
    private(set) var generation = UUID()
    private(set) var pendingPID: pid_t?
    private var start: NSPoint?

    mutating func invalidate() {
        generation = UUID(); start = nil; pendingPID = nil
    }
    mutating func begin(at point: NSPoint) {
        invalidate(); start = point
    }
    mutating func finish(at point: NSPoint, clicks: Int, shift: Bool, pid: pid_t) -> UUID? {
        guard let origin = start else { return nil }
        start = nil
        guard hypot(point.x - origin.x, point.y - origin.y) > 3 || clicks >= 2 || shift else { return nil }
        pendingPID = pid
        return generation
    }
    mutating func keyboard(pid: pid_t) -> UUID {
        invalidate(); pendingPID = pid
        return generation
    }
    mutating func activated(pid: pid_t?) {
        // Clicking into an inactive app can deliver activation after mouse-up.
        // Preserve that app's selection, but discard a read from another app.
        if let pendingPID, pendingPID != pid { invalidate() }
    }
    func accepts(_ request: UUID, frontPID: pid_t?) -> Bool {
        generation == request && pendingPID != nil && pendingPID == frontPID
    }
}

enum SelectionText {
    static func usable(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= TextLimits.characters else { return nil }
        return text
    }
    static func substring(_ text: String, location: Int, length: Int) -> String? {
        let value = text as NSString
        guard location >= 0, length > 0, length <= TextLimits.utf16Units,
              location <= value.length, length <= value.length - location else { return nil }
        return usable(value.substring(with: NSRange(location: location, length: length)))
    }
}

enum SelectionProbe {
    case text(String), empty, protected
}

// Only inspect the selected control and a few ancestors. Never scan a whole
// application tree or turn a control's complete value into selected text.
enum SelectionNodeSearch {
    static func resolve<Node: Equatable>(hit: Node?, focused: Node?,
        parent: (Node) -> Node?, read: (Node) -> SelectionProbe,
        isValid: () -> Bool = { true }, maximumDepth: Int = 4) -> String? {
        var visited: [Node] = []
        for seed in [hit, focused].compactMap({ $0 }) {
            var candidate: Node? = seed
            for _ in 0..<min(8, max(1, maximumDepth)) {
                guard isValid(), let node = candidate else { break }
                guard !visited.contains(node) else { break }
                visited.append(node)
                switch read(node) {
                case .protected: return nil
                case .text(let text):
                    guard isValid() else { return nil }
                    if let text = SelectionText.usable(text) { return text }
                case .empty: break
                }
                guard isValid() else { return nil }
                candidate = parent(node)
            }
        }
        return nil
    }
}

@MainActor
enum LocalTextSelection {
    static func text(in window: NSWindow, at screenPoint: NSPoint) -> String? {
        guard let content = window.contentView else { return nil }
        let point = content.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        var view = content.hitTest(point)
        while let candidate = view {
            if let editor = candidate as? NSTextView { return selectedText(in: editor) }
            view = candidate.superview
        }
        return nil
    }
    static func selectedText(in editor: NSTextView) -> String? {
        guard editor.isSelectable, !editor.isFieldEditor, !editor.hasMarkedText() else { return nil }
        let range = editor.selectedRange()
        return SelectionText.substring(editor.string, location: range.location, length: range.length)
    }
}

@MainActor
enum SelectionLookup {
    // Retry only for an explicit selection gesture; never poll the clipboard.
    static func resolve(
        read: () async -> String?,
        isValid: () -> Bool,
        delays: [UInt64] = [120_000_000, 180_000_000, 300_000_000],
        wait: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async -> String? {
        for delay in delays {
            do { try await wait(delay) } catch { return nil }
            guard !Task.isCancelled, isValid() else { return nil }
            let result = await read()
            guard !Task.isCancelled, isValid() else { return nil }
            if let text = SelectionText.usable(result) { return text }
        }
        return nil
    }
}


enum SelectionAccessibilityProfile: Equatable {
    case standard, electron, chromium
    static func resolve(bundleID: String?, electron: Bool) -> Self {
        if electron { return .electron }
        let browsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
        return bundleID.map { browsers.contains($0) } == true ? .chromium : .standard
    }
    var activationAttribute: String? {
        switch self { case .standard: return nil; case .electron: return "AXManualAccessibility"; case .chromium: return "AXEnhancedUserInterface" }
    }
    var retryDelays: [UInt64] {
        // Chromium debounces its accessibility activation for two seconds.
        self == .chromium ? [120_000_000, 180_000_000, 300_000_000, 700_000_000, 1_000_000_000, 400_000_000] : [120_000_000, 180_000_000, 300_000_000]
    }
}

// Inspect key codes and modifiers only. Never retain or log typed characters.
enum KeyboardSelectionAction: Equatable {
    case ignore, dismiss, inspect, select
    static func resolve(keyCode: UInt16, flags: NSEvent.ModifierFlags, shortcuts: [ShortcutSpec] = []) -> Self {
        let flags = flags.intersection([.command, .control, .option, .shift, .function])
        if [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) { return .ignore }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= 256 }
        if flags.contains(.shift) { carbon |= 512 }
        if flags.contains(.option) { carbon |= 2048 }
        if flags.contains(.control) { carbon |= 4096 }
        if shortcuts.contains(where: { $0.keyCode == UInt32(keyCode) && $0.modifiers == carbon }) { return .dismiss }
        if keyCode == 0 && flags.contains(.command) { return .select } // Command-A
        if [115, 116, 119, 121, 123, 124, 125, 126].contains(keyCode) && flags.contains(.shift) { return .select }
        // Copy, paste, close, address bar and other commands must not reopen
        // an old bubble merely because the previous selection still exists.
        if flags.contains(.command) && [1, 3, 6, 7, 8, 9, 12, 13, 15, 17, 31, 35, 37, 43, 48].contains(keyCode) { return .dismiss }
        if [36, 48, 49, 51, 53, 76, 117].contains(keyCode) { return .dismiss }
        let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if !flags.intersection([.command, .control, .option, .function]).isEmpty || functionKeys.contains(keyCode) { return .inspect }
        return .dismiss // Ordinary typing and IME composition are not selection gestures.
    }
}
