// Sonuvi — GPL-3.0. Synthetic streams only; no user's source or clipboard.
import AppKit
import SwiftUI

@MainActor
func runStreamingDisplayTests() async {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
        guard value else { fatalError("FAIL: " + message) }; checks += 1
    }
    let documents = [
        "# Title\n**Bold** [link](https://example.com) and _emphasis_.\n\n- [x] Item\n> Quote\n",
        "| Name | Value |\n| --- | --- |\n| **A** | `a|b` |\n\n---\nFinal",
        "Before\n\n```swift\nlet value = \"**code**\"\n\n```\nAfter **bold**\n",
        "> ~~~~json\n{\"a\": 1}\n~~~\n~~~~\nAfter\n    indented code\n",
        "Emoji 👨‍👩‍👧‍👦 é 😀🧑🏽‍💻 **中文** 与 [链接](https://example.com)\n\n",
        "Start\n\n[reference]: https://example.com\nTrailing\n"
    ]
    for document in documents {
        let projection = MarkdownDisplayProjection()
        for end in document.indices {
            let value = String(document[...end])
            check(projection.update(value) == MarkdownDocument(value).plain, "Incremental projection matches full Markdown parsing at every token boundary")
        }
        check(projection.update(document) == MarkdownDocument(document).plain, "Complete display matches existing formatting")
        let parsed = projection.parsedLines
        _ = projection.update(document)
        check(projection.parsedLines == parsed, "Unchanged view updates perform no parsing")
        let replacement = "## Replacement\nA **new** document.\n"
        check(projection.update(replacement) == MarkdownDocument(replacement).plain, "Retry and replacement invalidate changed lines")
        check(projection.update("") == "", "Clearing the result clears cached text")
    }
    let projection = MarkdownDisplayProjection()
    _ = projection.update(String(repeating: "Stable **line**.\n", count: 500) + "Tail")
    let before = projection.parsedLines
    _ = projection.update(String(repeating: "Stable **line**.\n", count: 500) + "Tail changed")
    check(projection.parsedLines - before == 1, "Appending a token reparses only the final line")
    let storage = NSTextStorage(string: "")
    for value in ["😀", "😁", "😁 é", "😁 é 👨‍👩‍👧‍👦", "😁", "", "普通文字", "普通文字。", "**bold**"] {
        _ = StreamingTextUpdate.apply(value, to: storage)
        check(storage.string == value, "Text updates preserve Unicode through appends, replacements and deletion")
    }
    let view = TranslationTextView(); view.isEditable = false; view.isRichText = false
    view.font = .systemFont(ofSize: 15); view.textColor = .labelColor
    view.textContainer?.widthTracksTextView = true
    let renderer = PlainMarkdownResultView.Coordinator()
    renderer.update("**Hello** world", view: view); view.setSelectedRange(NSRange(location: 0, length: 5))
    let liveSize = view.textContainer!.containerSize
    renderer.update("**Hello** world, more text.", view: view)
    check(view.string == "Hello world, more text." && view.selectedRange() == NSRange(location: 0, length: 5), "Streaming preserves existing text selection")
    check(view.markdownBacking == "**Hello** world, more text.", "Copy retains complete Markdown backing")
    let height = renderer.height(width: 330)
    check(renderer.height(width: 330) == height && renderer.heights.count == 1, "Repeated size probes reuse cached layout")
    _ = renderer.height(width: 220)
    check(view.textContainer!.containerSize == liveSize, "Measuring probe widths never changes the displayed wrapping")
    renderer.update("# New\nSecond line", view: view)
    check(renderer.heights.isEmpty && renderer.height(width: 330) > 0, "Changed text invalidates measurement cache")

    let markers = ["⟦SONUVI_TEST_0⟧", "⟦SONUVI_TEST_1⟧", "⟦SONUVI_TEST_2⟧"]
    check(TranslationWork.partialBatch("⟦SON", markers: markers) == nil, "An incomplete first marker is hidden")
    check(TranslationWork.partialBatch("\n " + markers[0] + "First", markers: markers) == ["First"], "Leading whitespace does not suppress batch previews")
    for n in 1..<markers[1].count {
        let partial = markers[0] + "First" + String(markers[1].prefix(n))
        check(TranslationWork.partialBatch(partial, markers: markers) == ["First"], "An incomplete next marker never leaks to display")
    }
    check(TranslationWork.partialBatch(markers[0] + "First" + markers[1] + "Sec", markers: markers) == ["First", "Sec"], "Partially received fields display in source order")
    let formatted = "# Title\n\nFirst **bold** paragraph.\n\nSecond paragraph."
    let work = TranslationWork(formatted)
    var previews: [String] = []; var sawBatchPreview = false; var attempts = 0
    let final = try! await work.run(send: { text, update in
        attempts += 1
        if attempts == 1 { return "invalid whole-document layout" }
        guard let firstMarker = text.range(of: #"⟦SONUVI_[A-Z0-9]+_0⟧"#, options: .regularExpression) else { return text }
        let start = text.distance(from: text.startIndex, to: firstMarker.upperBound)
        let chars = Array(text)
        for end in stride(from: start + 1, through: chars.count, by: 3) { update(String(chars.prefix(end))) }
        update(text)
        sawBatchPreview = previews.contains { $0.contains("First") && !$0.contains("Second") }
        return text
    }, onUpdate: { previews.append($0) }, onProgress: { _,_,_ in })
    check(sawBatchPreview && final == formatted, "Batch translation displays received text before the request completes")
    check(previews.allSatisfy { !$0.contains("⟦SONUVI_") }, "Internal markers remain hidden throughout streaming")

    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TranslationFixtureProtocol.self]
    let expected = String(repeating: "中😀", count: 500)
    let chunks = expected.map { character -> String in
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": String(character)]]]])
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }.joined()
    TranslationFixtureProtocol.responseCode = 200; TranslationFixtureProtocol.headers = [:]
    TranslationFixtureProtocol.body = chunks + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    let request = try! DeepSeekClient.request(text: "Hello.", kind: .sentence, direction: .toChinese, model: "deepseek-flash", key: "fixture")
    var snapshots: [String] = []
    let output = try! await DeepSeekClient.stream(request, configuration: config) { snapshots.append($0) }
    check(output == expected && snapshots.last == expected, "Coalescing always flushes the exact final Unicode response")
    check(snapshots.allSatisfy { expected.hasPrefix($0) }, "Coalesced updates preserve stream order")

    // Compare the previous read-only render path with the new coordinator using
    // the same synthetic data and width. Timings are reported, never CI thresholds.
    let paragraph = "## Heading\nThis is a **bold phrase** with a [link](https://example.com/a-long-destination) and _emphasis_. 表格与段落应流畅显示。\n\n"
    let chars = Array(String(repeating: paragraph, count: 90))
    let frames = stride(from: 100, through: chars.count, by: 100).map { String(chars.prefix($0)) }
    var oldTimes: [Double] = [], newTimes: [Double] = []
    let optimized = PlainMarkdownResultView.Coordinator()
    let display = TranslationTextView(); display.isEditable = false; display.isRichText = false
    for frame in frames {
        var start = ProcessInfo.processInfo.systemUptime
        let plain = MarkdownDocument(frame).plain
        let oldStorage = NSTextStorage(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let oldLayout = NSLayoutManager(); let container = NSTextContainer(size: NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; oldStorage.addLayoutManager(oldLayout); oldLayout.addTextContainer(container); oldLayout.ensureLayout(for: container)
        oldTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        start = ProcessInfo.processInfo.systemUptime
        optimized.update(frame, view: display); _ = optimized.height(width: 340); _ = optimized.height(width: 340)
        newTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    check(display.string == MarkdownDocument(frames.last!).plain, "Long streaming display remains exact")
    func percentile(_ samples: [Double], _ fraction: Double) -> Double { let sorted = samples.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
    print(String(format: "RENDER: frames=%d baseline_p50=%.3fms baseline_p95=%.3fms incremental_p50=%.3fms incremental_p95=%.3fms", frames.count, percentile(oldTimes, 0.5), percentile(oldTimes, 0.95), percentile(newTimes, 0.5), percentile(newTimes, 0.95)))
    print("PASS: \(checks) streaming display checks")
}
