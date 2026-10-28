// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI

@MainActor
func runTranslationLayoutTests() async {
    _ = NSApplication.shared
    var count = 0
    func check(_ condition: Bool, _ name: String) {
        guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func snapshot(_ view: NSView, _ name: String) {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshots"),
              CommandLine.arguments.indices.contains(index + 1),
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: folder.appendingPathComponent(name + ".png"))
    }
    let model = AppModel(); model.previewMode = true
    model.source = String(repeating: "A long English paragraph to read locally.\n", count: 20)
    model.result = String(repeating: "这是一段用于检查滚动布局的译文，向下阅读时应该保留返回原文的入口。\n", count: 35)
    let hosting = NSHostingView(rootView: TranslateView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
    window.backgroundColor = .windowBackgroundColor
    window.orderBack(nil)
    hosting.layoutSubtreeIfNeeded()
    try? await Task.sleep(nanoseconds: 500_000_000)
    hosting.layoutSubtreeIfNeeded()
    let scrolls = descendants(hosting).compactMap { $0 as? NSScrollView }
    check(scrolls.count == 2, "Translation has outer viewport and capped source editor")
    check(scrolls.allSatisfy { $0.scrollerStyle == .overlay && $0.verticalScroller is TranslationScroller }, "Both scrollbars use transparent overlay thumbs")
    check(scrolls.allSatisfy { !$0.drawsBackground && !$0.contentView.drawsBackground }, "Neither scrollbar paints a backing track")
    check(scrolls.allSatisfy { $0.verticalScroller?.controlSize == .small }, "Both thumbs retain native small-size tracking")
    guard let outer = scrolls.first(where: { !($0 is ContentSizedTextScrollView) }),
          let inner = scrolls.first(where: { $0 is ContentSizedTextScrollView }) else { exit(1) }
    check(outer.contentView.bounds.minY < 2, "Expanded source starts at the top")
    inner.contentView.scroll(to: NSPoint(x: 0, y: 150)); inner.reflectScrolledClipView(inner.contentView)
    outer.contentView.scroll(to: NSPoint(x: 0, y: 280)); outer.reflectScrolledClipView(outer.contentView)
    hosting.layoutSubtreeIfNeeded(); try? await Task.sleep(nanoseconds: 300_000_000)
    snapshot(hosting, "source-collapsed")
    check(outer.contentView.bounds.minY > 250, "Long translation can scroll beyond the source card")
    // Send events only to this fixture window, never to the system event stream.
    let point = hosting.convert(NSPoint(x: 200, y: hosting.isFlipped ? 55 : hosting.bounds.height - 55), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        NSApp.postEvent(event, atStart: false)
    }
    try? await Task.sleep(nanoseconds: 500_000_000); hosting.layoutSubtreeIfNeeded()
    snapshot(hosting, "source-restored")
    check(outer.contentView.bounds.minY < 2, "Pressing recall returns outer viewport to source")
    check(inner.contentView.bounds.minY < 2, "Pressing recall also restores the first line of long source")
    check(outer.contentView.bounds.minY < 2 && SourceRecall.isVisible(sourceBottom: 234) == false, "Restored source no longer needs the recall strip")
    check(SourceRecall.summary("  Hello\n\n world\t again ") == "Hello world again", "Recall preview normalizes whitespace")
    check(SourceRecall.summary(String(repeating: "a", count: 10000)).count == 100, "Recall preview is bounded for long passages")
    check(!SourceRecall.isVisible(sourceBottom: 35) && SourceRecall.isVisible(sourceBottom: 34), "Recall appears before the source fully leaves the viewport")
    // Exercise both appearances without changing the user's appearance or windows.
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        hosting.appearance = NSAppearance(named: appearance)
        window.setContentSize(NSSize(width: 360, height: 500)); hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 100_000_000)
        snapshot(hosting, appearance == .aqua ? "light-narrow" : "dark-narrow")
        check(descendants(hosting).compactMap { $0 as? NSScrollView }.allSatisfy { $0.verticalScroller is TranslationScroller }, "Thin scrollbars survive appearance and width changes")
    }
    model.setSource("# Source title\n**Bold** [link](https://example.com)")
    model.result = "# 译文标题\n**加粗** [链接](https://example.com)"
    try? await Task.sleep(nanoseconds: 300_000_000); hosting.layoutSubtreeIfNeeded()
    let nativeViews = descendants(hosting).compactMap { $0 as? TranslationTextView }
    let plainResult = nativeViews.first { !$0.isEditable && $0.string == "译文标题\n加粗 链接" }
    let plainSource = nativeViews.first { $0.isEditable && $0.string == "Source title\nBold link" }
    check(plainResult != nil && plainSource != nil, "Both source and result show plain text without Markdown syntax")
    if let plainSource, let plainResult {
        let sourceWidth = plainSource.convert(plainSource.bounds, to: hosting).width
        let resultWidth = plainResult.convert(plainResult.bounds, to: hosting).width
        check(abs(sourceWidth - resultWidth) < 8 && resultWidth > 280, "Result text uses the same available width as the source editor")
        check(plainResult.textContainer?.widthTracksTextView == true && abs((plainResult.textContainer?.containerSize.width ?? 0) - plainResult.bounds.width) < 8, "Result text container tracks the visible width")
    }
    check(plainResult?.markdownBacking == model.result && plainSource?.markdownBacking == model.source, "Both native views retain the original Markdown behind display")
    check(plainResult?.font?.pointSize == 15 && plainSource?.font?.pointSize == 15 && plainResult?.isRichText == false && plainSource?.isRichText == false,
          "Complex source and result use a uniform plain-text font")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        hosting.appearance = NSAppearance(named: appearance)
        hosting.layoutSubtreeIfNeeded()
        check(plainSource?.textColor == .labelColor && plainResult?.textColor == .labelColor, "Both plain displays retain dynamic label colors in light and dark appearance")
        snapshot(hosting, appearance == .aqua ? "plain-markdown-light" : "plain-markdown-dark")
    }
    let contrast = ReadableRichTextView()
    contrast.appearance = NSAppearance(named: .darkAqua)
    contrast.textStorage?.setAttributedString(NSAttributedString(string: "Black text", attributes: [.foregroundColor: NSColor.black]))
    contrast.refreshDisplayColors()
    check((contrast.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor) == NSColor.labelColor,
          "Black document text is readable in dark appearance")
    check((contrast.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == NSColor.black,
          "Appearance adjustment leaves original document color unchanged")
    contrast.appearance = NSAppearance(named: .aqua); contrast.refreshDisplayColors()
    check(contrast.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil,
          "Original black text displays in light appearance")
    window.close()
    print("PASS: \(count) translation layout checks")
}
