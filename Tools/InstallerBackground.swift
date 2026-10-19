// Sonuvi — GPL-3.0. Precisely aligned Finder installer artwork, rendered at 2x.
import AppKit

let width = 660, height = 440
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
text("Sonuvi", y: 333, size: 31, weight: .semibold, alpha: 0.96)
text("拖入「应用程序」，开始自然朗读与翻译", y: 302, size: 14, weight: .regular, alpha: 0.58)
let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 290, y: 215)); arrow.line(to: NSPoint(x: 368, y: 215))
arrow.move(to: NSPoint(x: 356, y: 226)); arrow.line(to: NSPoint(x: 368, y: 215)); arrow.line(to: NSPoint(x: 356, y: 204))
arrow.lineWidth = 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor.black.withAlphaComponent(0.28).setStroke(); arrow.stroke()
text("内置本地模型  ·  28 个英文音色", y: 86, size: 12, weight: .medium, alpha: 0.64)
text("更新时先退出旧版，拖入后选择「替换」；再从「应用程序」打开", y: 60, size: 11, weight: .regular, alpha: 0.43)
text("Apple Silicon  ·  macOS 26.2+", y: 25, size: 10, weight: .regular, alpha: 0.30)
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
