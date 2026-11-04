// Sonuvi — GPL-3.0. Generated pixels and text; never uses the user's clipboard.
import AppKit
import SwiftUI
import CoreText

func makeSolidScreenshot(width: Int, height: Int, gray: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@MainActor
func runScreenshotOverlayTests() async {
    var checks = 0
    func check(_ condition: Bool, _ message: String) { guard condition else { fatalError("FAIL: " + message) }; checks += 1 }
    let size = ScreenshotDisplaySpec.pixelSize(points: CGSize(width: 1512, height: 982), scale: 2)
    check(size.width == 3024 && size.height == 1964, "Retina capture requests two actual pixels per point")
    let fractional = ScreenshotDisplaySpec.pixelSize(points: CGSize(width: 10.25, height: 11.75), scale: 2)
    check(fractional.width == 21 && fractional.height == 24, "Fractional display bounds round outward")
    let retina = CapturedDisplay(frame: CGRect(x: -300, y: 50, width: 300, height: 150), image: makeSolidScreenshot(width: 600, height: 300, gray: 0.9))
    let standard = CapturedDisplay(frame: CGRect(x: 0, y: 50, width: 200, height: 150), image: makeSolidScreenshot(width: 200, height: 150, gray: 0.1))
    let frozen = FrozenCapture(displays: [retina, standard])
    check(frozen.crop(retina.frame)?.width == 600 && frozen.crop(standard.frame)?.width == 200, "Mixed-DPI displays keep their native pixels without downsampling")
    let joined = frozen.crop(CGRect(x: -100, y: 50, width: 200, height: 100))!
    check(joined.width == 400 && joined.height == 200, "Cross-display crops preserve the highest source scale")
    let aligned = frozen.alignedRect(CGRect(x: -299.75, y: 50.25, width: 40.2, height: 20.2))
    check(frozen.crop(aligned)?.width == Int(aligned.width * 2) && frozen.crop(aligned)?.height == Int(aligned.height * 2), "Overlay frames align to capture pixels instead of fractional resampling")
    check(frozen.crop(CGRect(x: 900, y: 900, width: 20, height: 20)) == nil, "Out-of-screen crops cannot create an unrelated image")

    let lines = [
        ScreenshotTextLine(text: "First English line.", bounds: CGRect(x: 0.05, y: 0.8, width: 0.4, height: 0.04), confidence: 1),
        ScreenshotTextLine(text: "Second English line.", bounds: CGRect(x: 0.05, y: 0.745, width: 0.4, height: 0.04), confidence: 1),
        ScreenshotTextLine(text: "Right column.", bounds: CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.04), confidence: 1),
        ScreenshotTextLine(text: "下一段中文。", bounds: CGRect(x: 0.05, y: 0.69, width: 0.4, height: 0.04), confidence: 1)
    ]
    let document = ScreenshotDocument(lines: lines)
    check(document.regions.count == 3, "OCR groups nearby paragraph lines while preserving columns and language direction")
    check(document.regions.first?.text == "First English line.\nSecond English line.", "Paragraph line order is preserved")
    check(document.regions.contains { $0.text == "下一段中文。" && $0.direction == .toEnglish }, "Chinese screen regions translate toward English")
    let labels = ScreenshotDocument(lines: ["Copy", "Paste", "Delete"].enumerated().map { index, text in
        ScreenshotTextLine(text: text, bounds: CGRect(x: 0.1, y: 0.8 - CGFloat(index) * 0.055, width: 0.2, height: 0.04), confidence: 1)
    })
    check(labels.regions.count == 3, "Separate menu labels keep their own screen positions instead of becoming a paragraph")
    let recognized = try! await OCRService.recognizeDocument(.image(try! makeOCRFixture()), cpuOnly: true)
    let english = recognized.regions.first { $0.text.contains("Hello David") }!
    let chinese = recognized.regions.first { $0.text.contains("公司") }!
    check(english.bounds.midY > chinese.bounds.midY, "Vision coordinates map to AppKit without an extra vertical flip")
    check(recognized.regions.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.bounds) }, "Recognized regions stay within the captured image")

    let canvasSize = CGSize(width: 500, height: 300)
    let regions = [ScreenshotTextRegion(id: 0, text: "Hello", bounds: CGRect(x: 0.1, y: 0.7, width: 0.35, height: 0.06), lineHeight: 0.06),
                   ScreenshotTextRegion(id: 1, text: "Below", bounds: CGRect(x: 0.1, y: 0.4, width: 0.35, height: 0.06), lineHeight: 0.06)]
    let placement = ScreenshotLayout.placement(region: regions[0], text: String(repeating: "Long translated text. ", count: 30), regions: regions, size: canvasSize)
    check(placement.fontSize >= 9 && placement.scrolls, "Long translations remain readable and scroll instead of shrinking indefinitely")
    check(placement.frame.minY >= ScreenshotLayout.rect(regions[1].bounds, in: canvasSize).maxY + 2, "Adaptive text never covers the next text block")
    check(CGRect(origin: .zero, size: canvasSize).contains(placement.frame), "Adaptive frames stay inside the selected screenshot")
    let labelRegions = [ScreenshotTextRegion(id: 4, text: "设置", bounds: CGRect(x: 0.1, y: 0.7, width: 0.06, height: 0.05), lineHeight: 0.05),
                        ScreenshotTextRegion(id: 5, text: "Other", bounds: CGRect(x: 0.4, y: 0.7, width: 0.2, height: 0.05), lineHeight: 0.05)]
    let label = ScreenshotLayout.placement(region: labelRegions[0], text: "Settings", regions: labelRegions, size: canvasSize)
    check(label.frame.width > 34 && !label.scrolls && label.frame.maxX < 200, "Longer English labels use nearby blank space without covering the next label")
    for selection in [CGRect(x: -400, y: 0, width: 50, height: 50), CGRect(x: 100, y: 300, width: 250, height: 250)] {
        let screen = CGRect(x: -500, y: -100, width: 1000, height: 800)
        check(screen.contains(ScreenshotLayout.toolbarFrame(selection: selection, screen: screen, size: CGSize(width: 540, height: 84))), "Toolbar stays reachable near screen edges and negative origins")
    }
    for (gray, foreground) in [(CGFloat(1), NSColor.black), (CGFloat(0.1), NSColor.white), (CGFloat(0.5), NSColor.black)] {
        let colors = ScreenshotRegionColors.sample(image: makeSolidScreenshot(width: 200, height: 100, gray: gray), rect: CGRect(x: 0, y: 0, width: 100, height: 50), size: CGSize(width: 100, height: 50))
        check(colors.foreground == foreground, "Translated glyphs use contrast appropriate to the sampled background")
    }
    let canvas = ScreenshotCanvasView(image: makeSolidScreenshot(width: 1000, height: 600, gray: 1), size: canvasSize)
    let uiDocument = ScreenshotDocument(regions: regions)
    _ = canvas.update(document: uiDocument, values: [0: "你好，世界", 1: "下面的文字"], original: false)
    let scrolls = canvas.subviews.compactMap { $0 as? NSScrollView }
    check(scrolls.count == 2 && scrolls.allSatisfy { ($0.documentView as? NSTextView)?.isSelectable == true }, "Every translated region supports native selection and copying")
    _ = canvas.update(document: uiDocument, values: [0: "你好，世界", 1: "下面的文字"], original: true)
    check(scrolls.allSatisfy(\.isHidden), "Original toggle shows untouched frozen pixels")

    let work = ScreenshotTranslationWork(document: uiDocument)
    var requests = 0; var previews: [[Int: String]] = []
    try! await work.run(send: { text, direction, update in
        requests += 1; check(direction == .toChinese, "English region requests use the correct target language")
        let output = text.replacingOccurrences(of: "Hello", with: "你好").replacingOccurrences(of: "Below", with: "下面")
        for end in output.indices { update(String(output[...end])) }
        return output
    }, onUpdate: { previews.append($0) }, onProgress: { _,_,_ in })
    check(requests == 1 && work.completed == [0: "你好", 1: "下面"], "One batch translates several regions without losing their IDs")
    check(previews.contains { $0[0] == "你好" && $0[1] == nil } && previews.allSatisfy { !$0.values.contains(where: { $0.contains("⟦SONUVI_") }) }, "Partial region previews arrive before completion without leaking markers")
    let fallback = ScreenshotTranslationWork(document: uiDocument); requests = 0
    try! await fallback.run(send: { text, _,_ in requests += 1; return text.contains("⟦SONUVI_") ? "invalid alignment" : text }, onUpdate: { _ in }, onProgress: { _,_,_ in })
    check(requests == 3 && fallback.completed == [0: "Hello", 1: "Below"], "Invalid batch alignment safely falls back to individual regions")
    let resumable = ScreenshotTranslationWork(document: uiDocument); requests = 0
    do {
        try await resumable.run(send: { text,_,_ in
            requests += 1
            if text.contains("⟦SONUVI_") { return "invalid" }
            if text == "Below" { throw TranslateError.message("fixture offline") }
            return text
        }, onUpdate: { _ in }, onProgress: { _,_,_ in }); fatalError("Failure accepted")
    } catch { check(resumable.completed == [0: "Hello"], "Failed and partial regions never become completed translations") }
    requests = 0
    try! await resumable.run(send: { text,_,_ in requests += 1; return text }, onUpdate: { _ in }, onProgress: { _,_,_ in })
    check(requests == 1 && resumable.completed.count == 2, "Retry resumes only unfinished screenshot regions")
    let cancelled = ScreenshotTranslationWork(document: uiDocument)
    let task = Task { @MainActor in try await cancelled.run(send: { text,_,_ in try await Task.sleep(nanoseconds: 1_000_000_000); return text }, onUpdate: { _ in }, onProgress: { _,_,_ in }) }
    await Task.yield(); task.cancel()
    do { try await task.value; fatalError("Cancellation accepted") } catch { check(cancelled.completed.isEmpty, "Closing or canceling cannot commit stale screenshot results") }

    let literal = ScreenshotTranslationWork(document: ScreenshotDocument(regions: [ScreenshotTextRegion(id: 7, text: "* Required", bounds: .zero, lineHeight: 0.02)]))
    try! await literal.run(send: { _,_,_ in "* 必填" }, onUpdate: { _ in }, onProgress: { _,_,_ in })
    check(literal.completed[7] == "* 必填", "Visible UI punctuation is retained instead of interpreted as Markdown")

    let controller = ScreenshotTranslationController(image: canvas.image, selection: CGRect(origin: .zero, size: canvasSize), modelName: "fixture")
    controller.model.document = uiDocument; controller.model.completed = work.completed
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    controller.copy(to: board)
    check(board.string(forType: .string) == "你好\n\n下面", "Copy translation uses completed regions in reading order")
    controller.copyImage(to: board)
    let copiedImage = NSBitmapImageRep(data: board.data(forType: .png)!)!
    check(copiedImage.pixelsWide == 1000 && copiedImage.pixelsHigh == 600, "Copied translated PNG keeps the original Retina pixel dimensions")
    let copiedText = try! await OCRService.recognizeDocument(.image(copiedImage.cgImage!), cpuOnly: true).text
    check(copiedText.contains("你好") && copiedText.contains("下面"), "Copied translated images contain readable rendered translations")
    controller.model.original = true; controller.copyImage(to: board)
    check(NSBitmapImageRep(data: board.data(forType: .png)!)?.pixelsWide == 1000, "Copy original image preserves native resolution")
    controller.model.original = true; controller.copy(to: board)
    check(board.string(forType: .string) == "Hello\n\nBelow", "Copy original preserves the recognized source")
    controller.close(); controller.close()
    print("PASS: \(checks) Retina screenshot and in-place translation checks")
}

@MainActor
func runRetinaCaptureTest() {
    guard CGPreflightScreenCaptureAccess() else { fputs("Existing screen recording permission is required; none requested.\n", stderr); exit(2) }
    OCRService.beginSnapshot { result in
        do {
            let frozen = try result.get()
            for screen in NSScreen.screens {
                guard let display = frozen.displays.first(where: { $0.frame == screen.frame }) else { fatalError("Missing display") }
                let target = ScreenshotDisplaySpec.pixelSize(points: screen.frame.size, scale: screen.backingScaleFactor)
                guard display.image.width >= target.width && display.image.height >= target.height else { fatalError("Downsampled Retina screenshot") }
                print("PASS: screen points=\(Int(screen.frame.width))x\(Int(screen.frame.height)) pixels=\(display.image.width)x\(display.image.height) scale=\(screen.backingScaleFactor)")
            }
            exit(0)
        } catch { fputs("Capture verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}

private var screenshotFixtureWindow: NSWindow?
@MainActor
func runScreenshotOverlayFixture() {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: CGRect(x: 280, y: 180, width: 720, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Sonuvi Screenshot Test · Synthetic Text Only"; window.isReleasedWhenClosed = false
    let view = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 420)); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.cgColor
    for (text, rect, size) in [
        ("Read without leaving this page", CGRect(x: 32, y: 334, width: 650, height: 40), CGFloat(26)),
        ("Translate the selected area in place.", CGRect(x: 32, y: 275, width: 650, height: 30), CGFloat(18)),
        ("Keep paragraphs readable. Copy the text you need.", CGRect(x: 32, y: 235, width: 650, height: 30), CGFloat(18)),
        ("中文界面也可以直接翻译成英文。", CGRect(x: 32, y: 142, width: 650, height: 34), CGFloat(20)),
        ("Retina test: 1234567890  AaBbCc  •  crisp text", CGRect(x: 32, y: 65, width: 650, height: 30), CGFloat(14))] {
        let field = NSTextField(labelWithString: text); field.frame = rect; field.font = .systemFont(ofSize: size); field.textColor = .black; view.addSubview(field)
    }
    let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
    submenu.addItem(withTitle: "Quit Test Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
    window.contentView = view; screenshotFixtureWindow = window
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    print("Synthetic screenshot fixture ready")
}
