// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI

@MainActor
func runEditorTests() {
    _ = NSApplication.shared
    let scroll = ContentSizedTextScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    let editor = TranslationTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    editor.font = .systemFont(ofSize: 15)
    editor.isVerticallyResizable = true; editor.textContainerInset = .zero
    editor.textContainer?.lineFragmentPadding = 0
    editor.textContainer?.widthTracksTextView = true
    scroll.documentView = editor
    scroll.scrollerStyle = .overlay
    var height: CGFloat = 0
    scroll.onHeightChanged = { height = $0 }
    func check(_ condition: Bool, _ name: String) {
        guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        print("PASS: \(name)")
    }
    editor.string = "Hello"; scroll.measureContent()
    let short = height
    check(height == 24 && !scroll.hasVerticalScroller, "Single line is compact")
    editor.string = "Hello\nworld\nagain"; scroll.measureContent()
    check(height > short && height < 180 && !scroll.hasVerticalScroller, "Explicit newlines grow editor")
    editor.string = String(repeating: "A sentence wraps naturally. ", count: 5); scroll.measureContent()
    let wide = height
    scroll.setFrameSize(NSSize(width: 180, height: 24)); scroll.measureContent()
    check(height > wide, "Narrower width remeasures wrapped content")
    editor.string = String(repeating: "Long content in the source editor.\n", count: 30); scroll.measureContent()
    check(height == 180 && scroll.hasVerticalScroller && editor.frame.height > height, "Overflow caps viewport and scrolls")
    editor.string = ""; scroll.measureContent()
    check(height == 24 && !scroll.hasVerticalScroller, "Deleting content shrinks and removes scrollbar")
    editor.isSelectable = true; editor.string = "A😀English example"; editor.setSelectedRange(NSRange(location: 3, length: 7))
    check(LocalTextSelection.selectedText(in: editor) == "English", "Local menu reads only the selected UTF-16 range")
    editor.setSelectedRange(NSRange(location: 3, length: 0))
    check(LocalTextSelection.selectedText(in: editor) == nil, "Caret does not open a menu for the entire source")
    editor.setSelectedRange(NSRange(location: 3, length: 7)); editor.isFieldEditor = true
    check(LocalTextSelection.selectedText(in: editor) == nil, "Settings and secure field editors are excluded")
    editor.isFieldEditor = false
    let testWindow = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 360, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    testWindow.isReleasedWhenClosed = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
    let localEditor = NSTextView(frame: NSRect(x: 10, y: 10, width: 200, height: 60))
    localEditor.string = "Local reading"; localEditor.isSelectable = true
    localEditor.setSelectedRange(NSRange(location: 0, length: 5)); container.addSubview(localEditor)
    testWindow.contentView = container
    let inside = testWindow.convertPoint(toScreen: NSPoint(x: 25, y: 25))
    check(LocalTextSelection.text(in: testWindow, at: inside) == "Local", "Window coordinates hit the selected text view")
    let outside = testWindow.convertPoint(toScreen: NSPoint(x: 300, y: 80))
    check(LocalTextSelection.text(in: testWindow, at: outside) == nil, "Clicking toolbar or empty space cannot reuse stale text")
    // Exercise the production bridge with NSTextInputClient composition calls,
    // including redraws while a candidate is still being composed.
    var value = ""
    let binding = Binding<String>(get: { value }, set: { value = $0 })
    let representation = TranslationEditor(text: binding, height: .constant(24), focusRequest: 0, onSelection: { _, _, _ in })
    let coordinator = TranslationEditor.Coordinator(representation)
    let input = TranslationTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
    input.isEditable = true; input.isRichText = false; input.allowsUndo = true
    input.delegate = coordinator
    input.onCompositionEnded = { coordinator.commit($0) }
    testWindow.contentView = input
    testWindow.makeFirstResponder(input)
    let unspecified = NSRange(location: NSNotFound, length: 0)
    input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
    check(input.hasMarkedText() && value.isEmpty, "Uncommitted pinyin stays owned by the input method")
    for _ in 0..<20 { coordinator.synchronize(input) }
    check(input.string == "ni" && input.hasMarkedText(), "Unrelated SwiftUI redraws preserve the marked range")
    input.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: unspecified)
    input.insertText("你好", replacementRange: unspecified)
    check(value == "你好" && input.string == value && !input.hasMarkedText(), "Chinese candidate commits once without losing characters")
    let suffix = "，English 😀 123"
    for character in suffix {
        input.insertText(String(character), replacementRange: unspecified)
        coordinator.synchronize(input)
    }
    check(value == "你好" + suffix && input.selectedRange().location == (value as NSString).length, "Rapid mixed Unicode typing preserves content and caret")
    let beforeComposition = value
    input.setMarkedText("ceshi", selectedRange: NSRange(location: 5, length: 0), replacementRange: unspecified)
    value = "External selection"
    coordinator.synchronize(input)
    check(input.hasMarkedText() && input.string.hasPrefix(beforeComposition), "External source replacement does not interrupt candidate composition")
    input.insertText("测试", replacementRange: unspecified)
    check(value == "External selection" && input.string == value, "Deferred external source wins after composition finishes")
    input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
    input.setMarkedText("test", selectedRange: NSRange(location: 4, length: 0), replacementRange: unspecified)
    input.unmarkText()
    check(value == "External selectiontest", "Unmark without a separate change notification still synchronizes text")
    let beforeCancelled = value
    input.setMarkedText("cancel", selectedRange: NSRange(location: 6, length: 0), replacementRange: unspecified)
    input.insertText("", replacementRange: unspecified)
    check(value == beforeCancelled, "Cancelling composition does not delete committed text")
    input.undoManager?.removeAllActions()
    let beforeUndo = value
    input.undoManager?.beginUndoGrouping()
    input.insertText("Z", replacementRange: unspecified)
    input.undoManager?.endUndoGrouping()
    let undoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: testWindow.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    _ = TextEditingCommands.perform(undoKey, in: input)
    check(input.string == beforeUndo && value == beforeUndo, "Undo updates the binding without replacing the native undo stack")
    let redoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
        windowNumber: testWindow.windowNumber, context: nil, characters: "Z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    _ = TextEditingCommands.perform(redoKey, in: input)
    check(input.string == beforeUndo + "Z" && value == input.string, "Redo preserves committed text and binding")
    value = String(repeating: "Long source 中文 😀\n", count: 5000)
    coordinator.synchronize(input)
    input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
    let started = ProcessInfo.processInfo.systemUptime
    for _ in 0..<30 { input.insertText("x", replacementRange: unspecified); coordinator.synchronize(input) }
    check(value.hasSuffix(String(repeating: "x", count: 30)), "Typing at the end of a long source does not roll back edits")
    print("METRIC: 30 long-source native edits: \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms")
    scroll.measureContent()
    let measured = scroll.measurementCount
    for _ in 0..<100 { scroll.scheduleMeasurement() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    check(scroll.measurementCount == measured, "Unchanged layouts do not repeatedly remeasure the full document")
    scroll.invalidateMeasurement(); scroll.invalidateMeasurement()
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    check(scroll.measurementCount == measured + 1, "Multiple content notifications coalesce into one measurement")

    let model = AppModel(); model.previewMode = true
    model.source = String(repeating: "Long model source 中文 😀\n", count: 4000)
    var notifications = 0
    let observation = model.objectWillChange.sink { notifications += 1 }
    let modelStarted = ProcessInfo.processInfo.systemUptime
    for _ in 0..<30 { model.editSource(model.source + "x") }
    let modelMilliseconds = Int((ProcessInfo.processInfo.systemUptime - modelStarted) * 1000)
    check(notifications == 30, "Idle editor emits one model change per committed edit, not repeated resets")
    print("METRIC: 30 long-source model edits: \(modelMilliseconds) ms")
    model.editSource("hello")
    model.translate()
    check(model.effectiveKind == .word && model.direction == .toChinese, "Immediate Translate uses the latest edit before the debounce expires")
    model.editSource("你好")
    model.translate()
    check(model.direction == .toEnglish, "Immediate Translate correctly classifies committed Chinese")
    withExtendedLifetime(observation) {}

}
