// Sonuvi — GPL-3.0. Frozen pixels with selectable, locally positioned translations.
import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class ScreenshotOverlayModel: ObservableObject {
    @Published var document: ScreenshotDocument?
    @Published var visible: [Int: String] = [:]
    @Published var completed: [Int: String] = [:]
    @Published var original = false
    @Published var busy = true
    @Published var error = ""
    @Published var status = "正在识别截图文字…"
    @Published var overflow = false
    @Published var copied = false
    @Published var needsSettings = false
    @Published var sourceLanguage = ScreenshotLanguage.automatic
    @Published var targetLanguage = ScreenshotLanguage.automatic
    @Published var selectingText = false
    @Published var pinned = false
    @Published var peeking = false
    @Published var editing = false
    var showsOriginal: Bool { original || peeking || busy || editing }
    var copyText: String {
        guard let document else { return "" }
        return original ? document.text : document.regions.compactMap { completed[$0.id] }.joined(separator: "\n\n")
    }
}

struct ScreenshotRegionColors {
    let background: NSColor
    let foreground: NSColor
    static func sample(image: CGImage, rect: CGRect, size: CGSize) -> ScreenshotRegionColors {
        let cropped = CapturedDisplay(frame: CGRect(origin: .zero, size: size), image: image).crop(rect) ?? image
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        var foreground: (CGFloat, CGFloat, CGFloat)?
        let result: (CGFloat, CGFloat, CGFloat) = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return (1,1,1) }
            context.interpolationQuality = .none; context.draw(cropped, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let data = bytes.bindMemory(to: UInt8.self)
            var buckets: [Int: (Int, Int, Int, Int)] = [:]
            for index in stride(from: 0, to: data.count, by: 4) where data[index + 3] > 200 {
                let r = Int(data[index]), g = Int(data[index + 1]), b = Int(data[index + 2])
                let key = (r / 32) * 64 + (g / 32) * 8 + b / 32
                let old = buckets[key] ?? (0,0,0,0); buckets[key] = (old.0 + 1, old.1 + r, old.2 + g, old.3 + b)
            }
            guard let best = buckets.values.max(by: { $0.0 < $1.0 }) else { return (1,1,1) }
            let denominator = CGFloat(best.0) * 255
            var background = (CGFloat(best.1) / denominator, CGFloat(best.2) / denominator, CGFloat(best.3) / denominator)
            let bucket = (Int(background.0 * 255) / 32) * 64 + (Int(background.1 * 255) / 32) * 8 + Int(background.2 * 255) / 32
            var exact: [Int: Int] = [:]
            for index in stride(from: 0, to: data.count, by: 4) {
                let r = Int(data[index]), g = Int(data[index+1]), b = Int(data[index+2])
                if (r/32)*64 + (g/32)*8 + b/32 == bucket { exact[(r << 16) | (g << 8) | b, default: 0] += 1 }
            }
            if let mode = exact.max(by: { $0.value < $1.value }), mode.value > best.0 / 3 {
                background = (CGFloat((mode.key >> 16) & 255)/255, CGFloat((mode.key >> 8) & 255)/255, CGFloat(mode.key & 255)/255)
            }
            let ink = buckets.values.filter { $0.0 >= 12 }.max { lhs, rhs in
                func distance(_ v: (Int,Int,Int,Int)) -> CGFloat {
                    let d = CGFloat(v.0) * 255
                    return abs(CGFloat(v.1)/d-background.0) + abs(CGFloat(v.2)/d-background.1) + abs(CGFloat(v.3)/d-background.2)
                }
                return distance(lhs) < distance(rhs)
            }
            if let ink {
                let d = CGFloat(ink.0) * 255
                let color = (CGFloat(ink.1)/d, CGFloat(ink.2)/d, CGFloat(ink.3)/d)
                if abs(color.0-background.0) + abs(color.1-background.1) + abs(color.2-background.2) > 0.45 { foreground = color }
            }
            return background
        }
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let brightness = 0.2126 * linear(result.0) + 0.7152 * linear(result.1) + 0.0722 * linear(result.2)
        let ink = foreground.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } ?? (brightness > 0.179 ? .black : .white)
        return ScreenshotRegionColors(background: NSColor(srgbRed: result.0, green: result.1, blue: result.2, alpha: 1), foreground: ink)
    }
}

@MainActor
enum ScreenshotImageRenderer {
    static func background(image: CGImage, size: CGSize, document: ScreenshotDocument, values: [Int: String]) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
        for region in document.regions where values[region.id] != nil && values[region.id] != region.text {
            for box in region.sourceBounds {
                let rect = ScreenshotLayout.rect(box, in: size).insetBy(dx: -1.5, dy: -1)
                let color = ScreenshotRegionColors.sample(image: image, rect: rect, size: size)
                context.setFillColor(color.background.cgColor); context.fill(rect)
            }
        }
        return context.makeImage()
    }
    static func render(image: CGImage, size: CGSize, document: ScreenshotDocument?, values: [Int: String], original: Bool) -> CGImage? {
        if original { return image }
        guard let document, size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let cleaned = background(image: image, size: size, document: document, values: values) ?? image
        context.draw(cleaned, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for region in document.regions {
            guard let text = values[region.id], !text.isEmpty, text != region.text else { continue }
            let placement = ScreenshotLayout.placement(region: region, text: text, regions: document.regions, size: size)
            guard !placement.scrolls else { return nil } // Do not export clipped translations as a complete image.
            let color = ScreenshotRegionColors.sample(image: image, rect: ScreenshotLayout.rect(region.bounds, in: size).insetBy(dx: -2, dy: -2), size: size)
            context.saveGState(); context.clip(to: placement.frame)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: placement.fontSize), .foregroundColor: color.foreground]
            NSAttributedString(string: text, attributes: attributes).draw(with: placement.frame.insetBy(dx: 2, dy: 2),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            context.restoreGState()
        }
        return context.makeImage()
    }
}

@MainActor
final class ScreenshotCanvasView: NSView {
    let image: CGImage
    private var textViews: [Int: NSScrollView] = [:]
    private var lastText: [Int: String] = [:]
    private var colors: [Int: ScreenshotRegionColors] = [:]
    private var cleaned: CGImage?
    private var renderedValues: [Int: String] = [:]
    init(image: CGImage, size: CGSize) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true; layer?.contents = image; layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest; layer?.minificationFilter = .nearest
        setAccessibilityLabel(L10n.text("截图翻译结果"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); layer?.contentsScale = window?.backingScaleFactor ?? 2 }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); layer?.contentsScale = window?.backingScaleFactor ?? 2 }
    func update(document: ScreenshotDocument?, values: [Int: String], original: Bool) -> Bool {
        guard let document else { return false }
        if renderedValues != values {
            cleaned = ScreenshotImageRenderer.background(image: image, size: bounds.size, document: document, values: values)
            renderedValues = values
        }
        layer?.contents = original ? image : (cleaned ?? image)
        var overflow = false
        for region in document.regions {
            guard let value = values[region.id], value != region.text, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                textViews[region.id]?.isHidden = true; continue
            }
            let placement = ScreenshotLayout.placement(region: region, text: value, regions: document.regions, size: bounds.size)
            overflow = overflow || placement.scrolls
            if let scroll = textViews[region.id], lastText[region.id] == value {
                scroll.isHidden = original; continue
            }
            let scroll: NSScrollView
            let text: NSTextView
            if let existing = textViews[region.id], let editor = existing.documentView as? NSTextView { scroll = existing; text = editor }
            else {
                scroll = NSScrollView(); scroll.borderType = .noBorder; scroll.drawsBackground = false
                scroll.scrollerStyle = .overlay; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
                scroll.wantsLayer = true; scroll.layer?.cornerRadius = 2
                text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.isRichText = false
                text.drawsBackground = false; text.textContainerInset = NSSize(width: 2, height: 2)
                text.textContainer?.lineFragmentPadding = 0; text.textContainer?.widthTracksTextView = true
                text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
                text.setAccessibilityLabel(L10n.text("区域译文"))
                scroll.documentView = text; textViews[region.id] = scroll; addSubview(scroll)
            }
            let color = colors[region.id] ?? ScreenshotRegionColors.sample(image: image,
                rect: ScreenshotLayout.rect(region.bounds, in: bounds.size).insetBy(dx: -2, dy: -2), size: bounds.size)
            colors[region.id] = color
            scroll.frame = placement.frame; scroll.backgroundColor = .clear
            scroll.hasVerticalScroller = placement.scrolls; scroll.isHidden = original
            text.frame = CGRect(x: 0, y: 0, width: placement.frame.width, height: max(placement.frame.height, placement.contentHeight))
            text.textContainer?.containerSize = NSSize(width: max(1, placement.frame.width - 4), height: CGFloat.greatestFiniteMagnitude)
            if let storage = text.textStorage { StreamingTextUpdate.apply(value, to: storage) }
            text.font = .systemFont(ofSize: placement.fontSize); text.textColor = color.foreground
            text.toolTip = value; lastText[region.id] = value
        }
        return overflow
    }
}
