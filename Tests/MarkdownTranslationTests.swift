import AppKit

@MainActor
func runMarkdownTranslationTests() async {
    var count = 0
    func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1; print("PASS: " + name) }
    let samples = [
        "# Heading\n\nA **bold** and _italic_ paragraph.\n\n> Quote\n>\n> More text\n",
        "- [x] Done\n- [ ] Next\n  - Nested\n    - Deep\n1. Ordered\n",
        "[Label](https://example.com/a_(b)?x=1 \"Title\") and ![Alt](image.png)\n<https://example.com>\n",
        "Text `x ** y` then ``a ` b``.\\*literal\\*\n",
        "```swift\nlet title = \"Never translate this\"\n```\nAfter code\n~~~python\nprint('keep')\n~~~\n",
        "| Name | Value |\n| :--- | ---: |\n| Apple | Red |\n\n---\nHeading\n=======\n",
        "# 标题\r\n\r\n**加粗** 与 [链接](https://example.com)\r\n",
        "\n    let code = 1\n\n你好 👨‍👩‍👧‍👦 é\n", "", "\n\n", "   ", String(repeating: "Long paragraph. ", count: 300)
    ]
    for sample in samples {
        let parts = MarkdownTranslation.parts(sample)
        check(parts.map { $0.text + $0.separator }.joined() == sample, "Markdown tokenization round-trip")
        let work = TranslationWork(sample)
        let output = try! await work.run(send: { value, _ in value }, onUpdate: { _ in }, onProgress: { _,_,_ in })
        check(output == sample, "Translation reconstruction retains exact Markdown")
    }
    let source = "# Hello\n\n**World** [Hello](https://example.com)\n```\nHello World\n```\n"
    var requests: [String] = []
    let translated = try! await TranslationWork(source).run(send: { value, _ in
        requests.append(value); return value.replacingOccurrences(of: "Hello", with: "你好").replacingOccurrences(of: "World", with: "世界")
    }, onUpdate: { _ in }, onProgress: { _,_,_ in })
    check(translated == "# 你好\n\n**世界** [你好](https://example.com)\n```\nHello World\n```\n", "Actual changed text retains headings, emphasis, links and code")
    check(requests.allSatisfy { !$0.contains("https://") && !$0.contains("```") && !$0.contains("Hello World") }, "Destinations and code never reach the translation model")
    check(MarkdownTranslation.escapeTranslation("**new** [x]") == "\\*\\*new\\*\\* \\[x\\]", "Generated formatting cannot change the source structure")
    let word = NSMutableAttributedString(string: "Title\nBold text", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
    word.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 22), range: NSRange(location: 0, length: 5))
    word.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 6, length: 4))
    check(MarkdownTranslation.importText(word.string, styled: word) == "## Title\n**Bold** text", "Word semantic styles become Markdown without document colors")
    let already = NSAttributedString(string: "# Heading\n**bold**", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    check(MarkdownTranslation.importText(already.string, styled: already) == already.string, "Existing Markdown is never converted twice")
    let wordHeading = NSMutableAttributedString(string: "Word heading\nNormal paragraph", attributes: [.font: NSFont.systemFont(ofSize: 11)])
    wordHeading.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 16), range: (wordHeading.string as NSString).range(of: "Word heading"))
    check(MarkdownTranslation.importText(wordHeading.string, styled: wordHeading) == "## Word heading\nNormal paragraph", "Typical Word-sized headings become Markdown headings")
    let wordList = NSMutableAttributedString(string: "1. Important item\n2. Normal item", attributes: [.font: NSFont.systemFont(ofSize: 14)])
    wordList.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: (wordList.string as NSString).range(of: "Important"))
    check(MarkdownTranslation.importText(wordList.string, styled: wordList) == "1. **Important** item\n2. Normal item", "Word list markers and inline bold both survive import")
    print("PASS: \(count) Markdown checks")
}
