// SpeechTrans — GPL-3.0. Synthetic fixture only: no screen/user content.
import Foundation
import AppKit
import CoreText
import Vision

func makeOCRFixture() throws -> CGImage {
    guard let context = CGContext(data: nil, width: 1000, height: 300, bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TranslateError.message("Cannot create fixture") }
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 300))
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 32, nil)
    for (line, y) in [("Hello David. Let's practice English together.", CGFloat(210)), ("我快到公司了，下次再练习。", CGFloat(120))] {
        let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 40, y: y); CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    guard let image = context.makeImage() else { throw TranslateError.message("Cannot draw fixture") }
    if let path = ProcessInfo.processInfo.environment["MUSE_OCR_FIXTURE_PATH"], let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: path)) }
    return image
}

func recognizeOCRFixture() throws -> String {
    let image = try makeOCRFixture()
    let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate; req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesCPUOnly = ProcessInfo.processInfo.environment["MUSE_TEST_OCR_CPU"] == "1"
    try VNImageRequestHandler(cgImage: image).perform([req])
    let result = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    guard result.contains("Hello David"), result.contains("公司"), result.contains("练习") else { throw TranslateError.message("Bilingual fixture mismatch: " + result) }
    return result
}

func runOCRTest() {
    do { _ = try recognizeOCRFixture(); print("PASS: native OCR recognized English and Chinese fixture") }
    catch { let e = error as NSError; fputs("OCR failed: \(e.domain) \(e.code) \(e.userInfo)\n", stderr); exit(1) }
}

func runOCRPipelineTest() async {
    do {
        let image = try makeOCRFixture()
        // Simulated Retina desktop with a negative origin and a screen above
        // primary: pixel coordinates must flip exactly once and clip safely.
        let frozen = FrozenCapture(frame: CGRect(x: -250, y: 100, width: 500, height: 150), image: image)
        guard frozen.pixelRect(CGRect(x: -230, y: 200, width: 100, height: 40)) == CGRect(x: 40, y: 20, width: 200, height: 80),
              frozen.crop(CGRect(x: 800, y: 800, width: 20, height: 20)) == nil,
              frozen.crop(CGRect(x: -300, y: 100, width: 100, height: 150))?.width == 100 else {
            throw TranslateError.message("Frozen screen coordinate mapping failed")
        }
        // Recognition must use saved pixels even after the live UI changes.
        guard let saved = frozen.crop(frozen.frame) else { throw TranslateError.message("Missing frozen frame") }
        let savedText = try await OCRService.recognize(.image(saved))
        guard savedText.contains("Hello David"), savedText.contains("公司") else {
            throw TranslateError.message("Frozen crop lost menu text or inverted image")
        }
        print("PASS: frozen frame crop preserves bilingual pixels, Retina scale and negative origins")
        let started = Date()
        let text = try await OCRService.recognize(.image(image))
        guard text.contains("Hello David"), text.contains("公司"), text.contains("练习") else {
            throw TranslateError.message("In-memory bilingual OCR mismatch")
        }
        print(String(format: "PASS: production in-memory OCR recognized both languages in %.3f seconds", Date().timeIntervalSince(started)))
        let task = Task { try await OCRService.recognize(.image(image)) }
        task.cancel()
        do {
            _ = try await task.value
            throw TranslateError.message("Canceled OCR returned stale text")
        } catch is CancellationError {
            print("PASS: canceled OCR does not deliver text")
        }
    } catch { fputs("OCR pipeline failed: \(error)\n", stderr); exit(1) }
}
