// Sonuvi — GPL-3.0. All image recognition and geometry remain on this Mac.
import AppKit

struct ScreenshotDisplaySpec {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int(ceil(points.width * max(1, scale)))), max(1, Int(ceil(points.height * max(1, scale)))))
    }
}

final class ScreenshotCaptureCollector {
    private let lock = NSLock()
    private var remaining: Int
    private var frames: [Int: CapturedDisplay] = [:]
    private var failure: Error?
    private let completion: (Result<FrozenCapture, Error>) -> Void
    init(count: Int, completion: @escaping (Result<FrozenCapture, Error>) -> Void) { remaining = count; self.completion = completion }
    func receive(index: Int, result: Result<CapturedDisplay, Error>) {
        lock.lock()
        switch result { case .success(let image): frames[index] = image; case .failure(let error): failure = failure ?? error }
        remaining -= 1
        let finished = remaining == 0
        let output: Result<FrozenCapture, Error> = failure.map { .failure($0) } ?? .success(FrozenCapture(displays: frames.sorted { $0.key < $1.key }.map(\.value)))
        lock.unlock()
        if finished { completion(output) }
    }
}

struct ScreenshotTextLine {
    let text: String
    let bounds: CGRect // Vision normalized coordinates, origin at bottom-left.
    let confidence: Float
}
struct ScreenshotTextRegion: Identifiable {
    let id: Int
    let text: String
    let bounds: CGRect
    let lineHeight: CGFloat
    var lineBounds: [CGRect] = []
    var direction: Direction { TextRules.direction(text) }
    var sourceBounds: [CGRect] { lineBounds.isEmpty ? [bounds] : lineBounds }
}
struct ScreenshotDocument {
    let regions: [ScreenshotTextRegion]
    let protectedBounds: [CGRect]
    var text: String { regions.map(\.text).joined(separator: "\n\n") }
    init(lines: [ScreenshotTextLine], imageSize: CGSize = CGSize(width: 1, height: 1), protectedBounds: [CGRect] = []) {
        let filtered = ScreenshotTextFilter.separate(lines, imageSize: imageSize)
        self.protectedBounds = protectedBounds + filtered.icons
        let lines = filtered.text

        struct Block { var lines: [ScreenshotTextLine]; var bounds: CGRect }
        var blocks: [Block] = []
        let sorted = lines.sorted {
            let rowA = Int(($0.bounds.midY / 0.012).rounded()), rowB = Int(($1.bounds.midY / 0.012).rounded())
            if rowA != rowB { return rowA > rowB }
            return $0.bounds.minX < $1.bounds.minX
        }
        for line in sorted {
            let candidate = blocks.indices.reversed().first { index in
                let block = blocks[index], last = block.lines.last!
                let gap = last.bounds.minY - line.bounds.maxY
                let height = max(last.bounds.height, line.bounds.height)
                let overlap = min(block.bounds.maxX, line.bounds.maxX) - max(block.bounds.minX, line.bounds.minX)
                return gap >= -0.15 * min(last.bounds.height, line.bounds.height) && gap <= height * 0.85
                    && abs(block.bounds.minX - line.bounds.minX) <= max(0.012, height * 0.5)
                    && overlap >= min(block.bounds.width, line.bounds.width) * 0.5
                    && line.bounds.height / last.bounds.height >= 0.6 && line.bounds.height / last.bounds.height <= 1.65
                    && max(last.text.count, line.text.count) >= 18
                    && TextRules.direction(last.text) == TextRules.direction(line.text)
            }
            if let index = candidate { blocks[index].lines.append(line); blocks[index].bounds = blocks[index].bounds.union(line.bounds) }
            else { blocks.append(Block(lines: [line], bounds: line.bounds)) }
        }
        regions = blocks.enumerated().map { index, block in
            let heights = block.lines.map { $0.bounds.height }.sorted()
            return ScreenshotTextRegion(id: index, text: block.lines.map(\.text).joined(separator: "\n"), bounds: block.bounds,
                                        lineHeight: heights[heights.count / 2], lineBounds: block.lines.map(\.bounds))
        }
    }
    init(regions: [ScreenshotTextRegion], protectedBounds: [CGRect] = []) { self.regions = regions; self.protectedBounds = protectedBounds }
}

// Geometry supplies context: a lone one-character table value is still text.
// Only isolated icon-like glyphs alongside a label are excluded from OCR/copy.
enum ScreenshotTextFilter {
    static let iconLike = Set("口囗日田目工山凵冂匚□▢▣◻︎◼︎⌘⌥⇧✕×＋➕⌕")
    static func iconPrefix(_ value: String, bounds: CGRect, label: CGRect, imageSize: CGSize, coloredTile: Bool) -> Bool {
        let box = ScreenshotLayout.rect(bounds, in: imageSize), rest = ScreenshotLayout.rect(label, in: imageSize)
        let enclosed = value.unicodeScalars.allSatisfy { (0x2460...0x24FF).contains($0.value) || (0x2190...0x21FF).contains($0.value) }
        let repeatedNumber = value.count == 2 && Set(value).count == 1 && value.allSatisfy(\.isNumber) && box.height > rest.height*1.12
        return (coloredTile || enclosed || repeatedNumber || (value.count == 1 && value.first.map(iconLike.contains) == true))
            && box.width <= box.height*2.5 && rest.minX-box.maxX > box.height*0.25
    }
    static func separate(_ lines: [ScreenshotTextLine], imageSize: CGSize) -> (text: [ScreenshotTextLine], icons: [CGRect]) {
        var text: [ScreenshotTextLine] = [], icons: [CGRect] = []
        for line in lines {
            let value = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = ScreenshotLayout.rect(line.bounds, in: imageSize)
            let symbolic = !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
                (0xE000...0xF8FF).contains(scalar.value) || (!CharacterSet.letters.contains(scalar) && !CharacterSet.decimalDigits.contains(scalar))
            }
            let nearLabel = lines.contains { other in
                let next = ScreenshotLayout.rect(other.bounds, in: imageSize)
                return other.text.count >= 2 && next.minX >= box.maxX && next.minX-box.maxX < box.height*3.5
                    && abs(next.midY-box.midY) < max(next.height, box.height)*0.45
                    && box.width < box.height*1.8
            }
            if symbolic || (value.count == 1 && value.first.map(iconLike.contains) == true && nearLabel) { icons.append(line.bounds) }
            else { text.append(line) }
        }
        return (text, icons)
    }
}

// Sample the original pixels once. Text expansion must stop at non-text graphics,
// button edges and table separators even when Vision produces no text there.
final class ScreenshotLayoutObstacles {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    private let size: CGSize
    init(image: CGImage, size: CGSize) {
        self.size = size; width = max(1, Int(size.width.rounded(.up))); height = max(1, Int(size.height.rounded(.up)))
        let width = self.width, height = self.height
        var data = [UInt8](repeating: 0, count: width*height*4)
        data.withUnsafeMutableBytes { bytes in
            let c = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        pixels = data
    }
    private func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let offset = ((height-1-max(0,min(height-1,y)))*width+max(0,min(width-1,x)))*4
        return (Int(pixels[offset]),Int(pixels[offset+1]),Int(pixels[offset+2]))
    }
    func leadingIcon(in normalized: CGRect) -> (icon: CGRect, label: CGRect)? {
        let source = ScreenshotLayout.rect(normalized, in: size).intersection(CGRect(origin: .zero,size: size))
        guard !source.isNull, source.width > source.height*1.5, source.height >= 3 else { return nil }
        let x0 = max(0,Int(source.minX)), x1 = min(width-1,Int(source.maxX)), y0 = max(0,Int(source.minY)), y1 = min(height-1,Int(source.maxY))
        var histogram: [Int:Int] = [:]
        for y in y0...y1 { for x in x0...x1 { let c = color(x,y); histogram[(c.0/16)*256+(c.1/16)*16+c.2/16,default:0] += 1 } }
        let key = histogram.max(by: {$0.value < $1.value})?.key ?? 4095
        let bg = ((key/256)*16+8,((key/16)%16)*16+8,(key%16)*16+8)
        func ink(_ x: Int,_ y: Int) -> Bool { let c = color(x,y); return max(abs(c.0-bg.0),abs(c.1-bg.1),abs(c.2-bg.2)) > 38 }
        var gapStart: Int?, hasInk = false
        for x in x0...min(x1, x0+Int(source.height*2.5)) {
            let occupied = (y0...y1).contains { ink(x,$0) }
            if occupied { hasInk = true; gapStart = nil }
            else if hasInk {
                if gapStart == nil { gapStart = x }
                if let start = gapStart, CGFloat(x-start+1) >= max(2,source.height*0.22) {
                    var end = x+1
                    while end <= x1 && !(y0...y1).contains(where: { ink(end,$0) }) { end += 1 }
                    guard end < x1 else { return nil }
                    func tight(_ left: Int,_ right: Int) -> CGRect {
                        var low = y1,high = y0
                        for xx in left...right { for yy in y0...y1 where ink(xx,yy) { low = min(low,yy); high = max(high,yy) } }
                        return CGRect(x: CGFloat(left)/size.width,y: CGFloat(low)/size.height,width: CGFloat(right-left+1)/size.width,height: CGFloat(max(1,high-low+1))/size.height)
                    }
                    return (tight(x0,max(x0,start-1)),tight(end,x1))
                }
            }
        }
        return nil
    }
    func limits(source: CGRect, right: CGFloat, bottom: CGFloat) -> (right: CGFloat, bottom: CGFloat) {
        let source = source.intersection(CGRect(origin: .zero, size: size))
        guard !source.isEmpty, !source.isNull else { return (right,bottom) }
        var histogram: [Int: Int] = [:]
        for y in stride(from: Int(source.minY), through: Int(source.maxY), by: 2) {
            for x in stride(from: Int(source.minX), through: Int(source.maxX), by: 2) {
                let c = color(x,y); histogram[(c.0/16)*256+(c.1/16)*16+c.2/16, default: 0] += 1
            }
        }
        let key = histogram.max(by: { $0.value < $1.value })?.key ?? 4095
        let bg = ((key/256)*16+8, ((key/16)%16)*16+8, (key%16)*16+8)
        func different(_ x: Int, _ y: Int) -> Bool {
            let c = color(x,y); return max(abs(c.0-bg.0),abs(c.1-bg.1),abs(c.2-bg.2)) > 38
        }
        var edge = right, floor = bottom
        let loY = Int(source.minY), hiY = Int(source.maxY)
        if Int(source.maxX)+2 < Int(right) {
            for x in (Int(source.maxX)+2)..<Int(right) {
                var occupied = 0
                for y in loY...hiY where different(x,y) { occupied += 1 }
                if occupied >= max(2, (hiY-loY+1)/4) { edge = CGFloat(x)-2; break }
            }
        }
        // A horizontal rule immediately below the row is a hard cell boundary.
        let loX = Int(source.minX), hiX = min(Int(edge), Int(source.maxX))
        if hiX >= loX, Int(source.minY)-2 > Int(bottom) {
            for y in stride(from: Int(source.minY)-2, through: Int(bottom), by: -1) {
                var occupied = 0
                for x in loX...hiX where different(x,y) { occupied += 1 }
                if occupied >= max(3, (hiX-loX+1)*3/4) { floor = CGFloat(y)+2; break }
            }
        }
        return (max(source.maxX,edge),min(source.minY,floor))
    }
}

struct ScreenshotTextPlacement {
    let frame: CGRect
    let fontSize: CGFloat
    let contentHeight: CGFloat
    let scrolls: Bool
}
enum ScreenshotLayout {
    static func rect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }
    static func measuredHeight(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let layout = NSLayoutManager(); let container = NSTextContainer(size: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY))
    }
    static func placement(region: ScreenshotTextRegion, text: String, regions: [ScreenshotTextRegion], size: CGSize, protectedBounds: [CGRect] = [], obstacles: ScreenshotLayoutObstacles? = nil) -> ScreenshotTextPlacement {
        let canvas = CGRect(origin: .zero, size: size)
        var original = rect(region.bounds, in: size).insetBy(dx: -2, dy: -2).intersection(canvas)
        guard !original.isNull, original.width > 1, original.height > 1 else {
            return ScreenshotTextPlacement(frame: .zero, fontSize: 9, contentHeight: 0, scrolls: false)
        }
        let gap: CGFloat = 4, padding: CGFloat = 4, widthPadding: CGFloat = 8
        let neighbors = regions.filter { $0.id != region.id }.map(\.bounds) + protectedBounds
        var right = canvas.maxX, below: CGFloat = 0
        for bounds in neighbors {
            let otherRect = rect(bounds, in: size)
            if otherRect.minX >= original.maxX-1 && min(otherRect.maxY,original.maxY)-max(otherRect.minY,original.minY) > 1 { right = min(right,otherRect.minX-gap) }
            if otherRect.maxY <= original.minY+1 && min(otherRect.maxX,max(original.maxX,right))-max(otherRect.minX,original.minX) > 1 { below = max(below,otherRect.maxY+gap) }
        }
        if let limits = obstacles?.limits(source: rect(region.bounds, in: size), right: right, bottom: below) { right = min(right,limits.right); below = max(below,limits.bottom) }
        let sourceWidth = region.text.components(separatedBy: .newlines).map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 100)]).size().width / 100
        }.max() ?? 1
        // Vision's vertical box includes language-dependent padding. Estimate
        // point size from both glyph width and height, so a 12 pt Chinese label
        // does not become a 20 pt English label after translation.
        let fromWidth = region.bounds.width * size.width / max(0.1, sourceWidth)
        let fromHeight = region.lineHeight * size.height * 1.25
        let preferred = (min(40, max(9, min(fromWidth, fromHeight))) * 2).rounded(.down) / 2
        if original.height <= region.lineHeight * size.height * 1.6 + padding {
            // Short UI labels may need more horizontal space when Chinese
            // becomes English. Stop before other text in the same row.
            let natural = text.components(separatedBy: .newlines).map {
                (NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: preferred)]).size().width)
            }.max() ?? original.width
            let extraWidth = min(max(0, right - original.minX), min(max(original.width * 5, preferred * 12), ceil(natural) + widthPadding + 2))
            original.size.width = max(original.width, extraWidth)
        }
        // Expand down only into empty space, never over the next text block.
        let maximumHeight = max(original.height, min(original.maxY - below, max(original.height * 2, preferred * 2.6 + padding)))
        var lower: CGFloat = min(9, preferred), upper = preferred
        for _ in 0..<8 {
            let middle = (lower + upper) / 2
            if measuredHeight(text, width: original.width - widthPadding, fontSize: middle) + padding <= maximumHeight { lower = middle }
            else { upper = middle }
        }
        let font = lower
        let content = measuredHeight(text, width: original.width - widthPadding, fontSize: font) + padding
        let height = max(original.height, min(maximumHeight, content))
        let frame = CGRect(x: floor(original.minX), y: floor(original.maxY - height), width: ceil(original.width), height: ceil(height)).intersection(canvas)
        return ScreenshotTextPlacement(frame: frame, fontSize: font, contentHeight: content, scrolls: content > frame.height + 0.5)
    }
    static func toolbarFrame(selection: CGRect, screen: CGRect, size: CGSize) -> CGRect {
        let x = max(screen.minX + 8, min(selection.midX - size.width / 2, screen.maxX - size.width - 8))
        let y = selection.minY - size.height - 8 >= screen.minY + 8 ? selection.minY - size.height - 8 : max(screen.minY + 8, selection.minY + 8)
        return CGRect(x: x, y: min(y, screen.maxY - size.height - 8), width: size.width, height: size.height)
    }
}
