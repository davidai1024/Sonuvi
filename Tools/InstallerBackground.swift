// Sonuvi — GPL-3.0. Precisely aligned Finder installer artwork, rendered at 2x.
import AppKit

let width = 660, height = 560
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(starting: NSColor(calibratedWhite: 0.97, alpha: 1), ending: NSColor(calibratedWhite: 0.94, alpha: 1))!.draw(in: bounds, angle: 90)
func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (value as NSString).draw(in: NSRect(x: 30, y: y, width: 600, height: size * 1.8), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.black.withAlphaComponent(alpha), .paragraphStyle: style])
}
text("Sonuvi", y: 453, size: 31, weight: .semibold, alpha: 0.96)
text("拖入「应用程序」，开始自然朗读与翻译", y: 422, size: 14, weight: .regular, alpha: 0.58)
let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 290, y: 335)); arrow.line(to: NSPoint(x: 368, y: 335))
arrow.move(to: NSPoint(x: 356, y: 346)); arrow.line(to: NSPoint(x: 368, y: 335)); arrow.line(to: NSPoint(x: 356, y: 324))
arrow.lineWidth = 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor.black.withAlphaComponent(0.28).setStroke(); arrow.stroke()
text("首次打开若提示「无法验证开发者」或「Apple 无法检查」", y: 232, size: 12, weight: .regular, alpha: 0.68)
text("先点「完成／好／取消」关闭提示，不要点「移到废纸篓」。", y: 210, size: 12, weight: .medium, alpha: 0.78)
text("双击下方入口，在「安全性」中找到 Sonuvi，点击「仍要打开」。", y: 188, size: 11, weight: .regular, alpha: 0.62)
text("若未自动定位：系统设置 → 隐私与安全性 → 向下找到「安全性」", y: 55, size: 10, weight: .regular, alpha: 0.48)
let includesVoice = CommandLine.arguments.contains("--bundled-voice")
text(includesVoice ? "Apple Silicon  ·  macOS 14.0+  ·  已内置 28 种英文音色" : "Apple Silicon  ·  macOS 14.0+  ·  本地模型按需免费下载", y: 25, size: 10, weight: .regular, alpha: 0.30)
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
