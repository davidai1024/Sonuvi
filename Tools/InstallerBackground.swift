// Sonuvi — GPL-3.0. Compact Finder installer artwork, rendered at 2x.
import AppKit

let width = 600, height = 390
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSColor(calibratedWhite: 0.98, alpha: 1).setFill(); bounds.fill()
func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat, alignment: NSTextAlignment = .center) {
    let style = NSMutableParagraphStyle(); style.alignment = alignment
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.black.withAlphaComponent(alpha), .paragraphStyle: style])
}
text("Sonuvi", rect: NSRect(x: 24, y: 310, width: 552, height: 40), size: 22, weight: .semibold, alpha: 0.94)
text("拖入「应用程序」即可安装", rect: NSRect(x: 24, y: 286, width: 552, height: 22), size: 12, alpha: 0.48)
let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 275, y: 219)); arrow.line(to: NSPoint(x: 325, y: 219))
arrow.move(to: NSPoint(x: 315, y: 229)); arrow.line(to: NSPoint(x: 325, y: 219)); arrow.line(to: NSPoint(x: 315, y: 209))
arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
NSColor.black.withAlphaComponent(0.30).setStroke(); arrow.stroke()
NSColor(calibratedWhite: 0.945, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 24, y: 52, width: 552, height: 78), xRadius: 12, yRadius: 12).fill()
NSColor.black.withAlphaComponent(0.08).setStroke()
let divider = NSBezierPath(); divider.move(to: NSPoint(x: 468, y: 66)); divider.line(to: NSPoint(x: 468, y: 116)); divider.lineWidth = 0.7; divider.stroke()
text("首次打开受阻？先点「完成」，不要移到废纸篓。", rect: NSRect(x: 40, y: 98, width: 420, height: 22), size: 11.5, alpha: 0.76, alignment: .left)
text("再到「隐私与安全性」点「仍要打开」。", rect: NSRect(x: 40, y: 76, width: 420, height: 22), size: 11.5, alpha: 0.60, alignment: .left)
text("Apple Silicon · macOS 14.0+", rect: NSRect(x: 24, y: 12, width: 552, height: 22), size: 10, alpha: 0.38)
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
