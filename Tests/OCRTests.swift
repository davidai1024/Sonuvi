// SpeechTrans — GPL-3.0. Synthetic fixture only: no screen/user content.
import Foundation
import AppKit
import CoreText
import Vision

func recognizeOCRFixture() throws -> String {
    guard let context = CGContext(data: nil, width: 1000, height: 300, bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TranslateError.message("Cannot create fixture") }
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 300))
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 32, nil)
    for (line, y) in [("Hello David. Let's practice English together.", CGFloat(210)), ("我快到公司了，下次再练习。", CGFloat(120))] {
        let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 40, y: y); CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    guard let image = context.makeImage() else { throw TranslateError.message("Cannot draw fixture") }
    if let path = ProcessInfo.processInfo.environment["MUSE_OCR_FIXTURE_PATH"], let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: path)) }
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
