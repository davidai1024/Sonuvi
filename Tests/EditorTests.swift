// Sonuvi — GPL-3.0.
import AppKit

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
}
