import AppKit

@MainActor
func runMarkdownDocumentTests() {
    var count = 0
    func check(_ result: Bool, _ message: String) { precondition(result, message); count += 1; print("PASS: " + message) }
    let source = "# Title\n\nA **bold** and _italic_ [link](https://example.com).\n> Quote\n- Item\n\n```swift\nlet value = \"**literal**\"\n```\n"
    let document = MarkdownDocument(source)
    check(document.plain == "Title\n\nA bold and italic link.\nQuote\nItem\n\nlet value = \"**literal**\"\n", "Complex Markdown displays as uniform plain text with code content intact")
    check(document.markdown == source, "Display never mutates Markdown backing")
    check(document.editingPlain(document.plain) == source, "Unchanged display keeps exact source")
    check(document.editingPlain(document.plain.replacingOccurrences(of: "bold", with: "strong")) == source.replacingOccurrences(of: "bold", with: "strong"), "Editing visible emphasis retains its hidden delimiters")
    check(document.editingPlain(document.plain.replacingOccurrences(of: "link", with: "website")) == source.replacingOccurrences(of: "[link]", with: "[website]"), "Editing link label retains destination")
    check(document.editingPlain(document.plain.replacingOccurrences(of: "Title", with: "New title")) == source.replacingOccurrences(of: "Title", with: "New title"), "Editing heading keeps hidden heading marker")
    check(document.editingPlain(document.plain.replacingOccurrences(of: "bold", with: "")) == source.replacingOccurrences(of: "**bold**", with: ""), "Deleting a complete styled word removes empty delimiters")
    let unicode = MarkdownDocument("**你好 👨‍👩‍👧‍👦 é** &copy; \\*")
    check(unicode.plain == "你好 👨‍👩‍👧‍👦 é © *", "Plain projection decodes entities and escapes without damaging Unicode")
    check(unicode.editingPlain(unicode.plain.replacingOccurrences(of: "你好", with: "您好")) == "**您好 👨‍👩‍👧‍👦 é** &copy; \\*", "UTF-16 edit mapping preserves emoji, combining marks and metadata")
    check(unicode.editingPlain(unicode.plain.replacingOccurrences(of: "©", with: "copy")) == "**你好 👨‍👩‍👧‍👦 é** copy \\*", "Entity editing replaces the complete source entity")
    check(document.editingPlain("").isEmpty, "Clearing the visible editor also removes hidden document metadata")
    let code = MarkdownDocument("```\nlet a = 1\n```\n")
    check(code.editingPlain("let a = **2**\n") == "```\nlet a = **2**\n```\n", "Editing code content never inserts Markdown escape characters")
    let table = MarkdownDocument("| Name | Value |\n| --- | --- |\n| A | B |")
    check(!table.plain.contains("|") && !table.plain.contains("---") && table.markdown.contains("| --- |"), "Table syntax remains hidden while backing retains table structure")
    let model = AppModel(); model.previewMode = true; model.setSource(source)
    check(model.sourceDisplay == document.plain && model.source == source, "Model separates display text from Markdown source")
    let edited = document.plain.replacingOccurrences(of: "bold", with: "strong")
    model.editSourceDisplay(edited)
    check(model.source == source.replacingOccurrences(of: "bold", with: "strong"), "Model edits translate display positions into Markdown positions")
    model.editSourceDisplay(document.plain)
    check(model.source == source, "Undo restores exact Markdown backing")
    model.editSourceDisplay(edited)
    check(model.source == source.replacingOccurrences(of: "bold", with: "strong"), "Redo restores Markdown metadata")
    model.setSource(source)
    let range = (model.sourceDisplay as NSString).range(of: "Item")
    model.pasteSourceMarkdown("**New** [link](https://new.example)", range: range)
    check(model.source.contains("- **New** [link](https://new.example)") && !model.sourceDisplay.contains("https://"), "Pasting into a plain selection retains new Markdown metadata")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents(); board.setString(source, forType: .string)
    check(MarkdownClipboard.readMatchingSelection(board, text: source) == source, "Selected Markdown source survives a plain-text copy")
    check(MarkdownClipboard.readMatchingSelection(board, text: document.plain) == source, "Rendered selection matches copied Markdown source")
    check(MarkdownClipboard.readMatchingSelection(board, text: "unrelated selection") == nil, "A different selection cannot reuse stale clipboard content")
    let editorCopy = "# Format test\n\nThis is a **bold phrase** and a [useful link](https://example.com).\n\n1. **First item** with details.\n2. Second item with _emphasis_.\n\n- A bullet point\n- Another point"
    let editorAX = "\u{fffc}# Format test\nThis is a bold phrase and a useful link.\n1. First item with details.\u{200b}    2. Second item with emphasis.\u{200b}    \n• A bullet point\u{200b}    - Another point"
    board.clearContents(); board.setString(editorCopy, forType: .string)
    check(MarkdownClipboard.readMatchingSelection(board, text: editorAX) == editorCopy, "Editor accessibility artifacts do not discard copied Markdown lists")
    check(MarkdownClipboard.readMatchingSelection(board, text: editorAX.replacingOccurrences(of: "Second", with: "Different")) == nil, "Changed selection is rejected despite layout normalization")
    let html = "<html><body><h1>Heading</h1><p>Some <strong>bold</strong> and <a href=\"https://example.com\">link</a>.</p><ul><li>One</li><li>Two</li></ul></body></html>"
    board.clearContents(); let item = NSPasteboardItem()
    item.setString("Heading\nSome bold and link.\nOne\nTwo", forType: .string)
    item.setData(Data(html.utf8), forType: .html); board.writeObjects([item])
    let htmlResult = MarkdownClipboard.read(board) ?? ""
    check(htmlResult.contains("# Heading") && htmlResult.contains("**bold**") && htmlResult.contains("[link](https://example.com)") && htmlResult.contains("- One") && htmlResult.contains("- Two"), "Copied HTML retains heading, links, bold and list items")
    board.clearContents(); let editorItem = NSPasteboardItem()
    editorItem.setString(editorCopy, forType: .string); editorItem.setData(Data(html.utf8), forType: .html); board.writeObjects([editorItem])
    check(MarkdownClipboard.read(board) == editorCopy, "Existing Markdown wins over an editor's HTML representation")
    MarkdownClipboard.write(source, to: board)
    check(board.string(forType: .string) == source, "Markdown editor receives original syntax as plain clipboard text")
    check(board.data(forType: .rtf) == nil, "Default copy cannot cause Markdown editors to prefer lossy rich text")
    print("PASS: \(count) plain-display document checks")
}
