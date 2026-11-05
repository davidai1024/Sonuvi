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
struct ScreenshotTextRegion: Identifiable, Equatable {
    let id: Int
    let text: String
    let bounds: CGRect
    let lineHeight: CGFloat
    var lineBounds: [CGRect] = []
    // A hard inner viewport, independent of the translated string's length.
    var viewport: CGRect? = nil
    var centeredInViewport = false
    var centerVerticallyInViewport = false
    var rightBoundaryKind = "unmeasured"
    var fontLineHeight: CGFloat? = nil
    var direction: Direction { TextRules.direction(text) }
    var sourceBounds: [CGRect] { lineBounds.isEmpty ? [bounds] : lineBounds }
}
struct ScreenshotDocument: Equatable {
    let regions: [ScreenshotTextRegion]
    let protectedBounds: [CGRect]
    var text: String { regions.map(\.text).joined(separator: "\n\n") }
    init(lines: [ScreenshotTextLine], imageSize: CGSize = CGSize(width: 1000, height: 1000), protectedBounds: [CGRect] = [], grouping: ((ScreenshotTextLine,ScreenshotTextLine) -> Bool)? = nil) {
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
                    && abs(block.bounds.minX - line.bounds.minX) <= max(2 / max(1,imageSize.width), height * imageSize.height / max(1,imageSize.width) * 0.5)
                    && overlap >= min(block.bounds.width, line.bounds.width) * 0.5
                    && line.bounds.height / last.bounds.height >= 0.6 && line.bounds.height / last.bounds.height <= 1.65
                    && max(last.text.count, line.text.count) >= 18
                    && TextRules.direction(last.text) == TextRules.direction(line.text)
                    && (grouping?(last,line) ?? true)
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
    private static let englishLabels: Set<String> = ["recent","all types","all locations","creator","last modified","new","open","starred","shared","cloud document","cloud documents","personal space","team space","my devices","label","labels","recycle bin","local","desktop","documents","downloads","wechat files","browse","frequently used","sync folder","workbench","wiki","calendar","messages","email","templates","update","me","guest","today","yesterday","最近","所有类型","全部类型","所有位置","文件位置","创建者","最后修改","最近修改","新建","打开","星标","已加星标","共享","已共享","云文档","个人空间","团队空间","我的设备","标签","回收站","本地","桌面","文档","文稿","下载","浏览","工作台","今天","昨天","我"]
    private static let compactLabels = Set(englishLabels.map { $0.replacingOccurrences(of:" ",with:"") })
    static func isDayTimeBoundary(day:String,remainder:String) -> Bool {
        let labels: Set<String> = ["今天","昨天","今日","昨日","today","yesterday"]
        return labels.contains(day.lowercased()) && remainder.range(of:#"^\d{1,2}[:：]\d{2}(?:\b|\s|$)"#,options:.regularExpression) != nil
    }
    static func isUILabel(_ body:String) -> Bool {
        guard body.count <= 80 else { return false }
        let lower = body.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
        return englishLabels.contains(lower) || compactLabels.contains(lower.replacingOccurrences(of:" ",with:""))
            || lower.hasSuffix(" ai chat") || lower.hasPrefix("search ") && lower.hasSuffix(".")
            || lower.hasPrefix("all locat") && (lower.hasSuffix("...") || lower.hasSuffix("…"))
    }
    static func detachedAdornment(_ token: String, body: String, icon: CGRect, label: CGRect, imageSize: CGSize, coloredTile: Bool = false) -> Bool {
        let han = body.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        let englishUI = isUILabel(body)
        let nonLatinLetters = token.unicodeScalars.filter { $0.value > 127 && CharacterSet.letters.contains($0) }.count
        let sidebarIcon = englishUI && icon.midX < 0.25 && nonLatinLetters <= 1
        let plainWord = token.count > 1 && token.allSatisfy { $0.isASCII && $0.isLetter }
        let numericMetadata = token.range(of:#"^[0-9.,:/%+\-]+$"#,options:.regularExpression) != nil && (token.count > 2 || !sidebarIcon)
        let smallUIAffix = token.count <= 6 && !token.isEmpty && !plainWord && !numericMetadata && (han >= 2 && body.count <= 18 || englishUI) && token.unicodeScalars.allSatisfy {
            sidebarIcon || $0.value < 128 || !CharacterSet.alphanumerics.contains($0) || (0x2460...0x24FF).contains($0.value)
        }
        let box = ScreenshotLayout.rect(icon,in: imageSize), rest = ScreenshotLayout.rect(label,in: imageSize)
        let gap = max(rest.minX-box.maxX,box.minX-rest.maxX)
        return (smallUIAffix || iconPrefix(token,bounds: icon,label: label,imageSize: imageSize,coloredTile: coloredTile))
            && box.width <= box.height*3 && gap >= max(1, min(box.height,rest.height)*0.22)
            && abs(box.midY-rest.midY) < max(box.height,rest.height)*0.6
    }
    static func separate(_ lines: [ScreenshotTextLine], imageSize: CGSize) -> (text: [ScreenshotTextLine], icons: [CGRect]) {
        var text: [ScreenshotTextLine] = [], icons: [CGRect] = []
        for line in lines {
            let value = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = ScreenshotLayout.rect(line.bounds, in: imageSize)
            let symbolic = !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
                (0xE000...0xF8FF).contains(scalar.value) || (!CharacterSet.letters.contains(scalar) && !CharacterSet.decimalDigits.contains(scalar))
            }
            if symbolic { icons.append(line.bounds);continue }
            let count = value.count
            let composite = count <= 6 && value.contains(where: {!$0.isLetter && !$0.isNumber}) && value.contains(where: \.isLetter)
            guard count == 1 || composite else { text.append(line);continue }
            let nearLabel = count == 1 && lines.contains { other in
                let next = ScreenshotLayout.rect(other.bounds,in:imageSize)
                return next.minX >= box.maxX && next.minX-box.maxX < box.height*3.5
                    && abs(next.midY-box.midY) < max(next.height,box.height)*0.45 && box.width < box.height*1.8 && other.text.count >= 2
            }
            let nearUI = lines.contains { other in
                let next = ScreenshotLayout.rect(other.bounds,in:imageSize)
                let gap = max(next.minX-box.maxX,box.minX-next.maxX)
                return gap >= 0 && gap < max(box.height,next.height)*2 && abs(next.midY-box.midY) < max(box.height,next.height)*0.6
                    && isUILabel(other.text)
            }
            let latinIcon = ["C","Y","V","v","d","G","Q","<",">"].contains(value) && nearUI
            let sidebarGlyph = count == 1 && !value.allSatisfy(\.isNumber) && line.bounds.midX < 0.25 && nearUI
            let compositeIcon = composite && lines.contains { other in
                let next = ScreenshotLayout.rect(other.bounds,in:imageSize)
                let gap = max(next.minX-box.maxX,box.minX-next.maxX)
                return gap >= 0 && gap < max(box.height,next.height)*2 && abs(next.midY-box.midY) < max(box.height,next.height)*0.6
                    && detachedAdornment(value,body:other.text,icon:line.bounds,label:other.bounds,imageSize:imageSize)
            }
            if latinIcon || sidebarGlyph || compositeIcon || (count == 1 && value.first.map(iconLike.contains) == true && nearLabel) { icons.append(line.bounds) }
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
    private func background(in source: CGRect) -> (Int,Int,Int) {
        var buckets: [Int:Int] = [:]
        let x0 = Int(floor(source.minX))-3,x1 = Int(ceil(source.maxX))+3,y0 = Int(floor(source.minY))-3,y1 = Int(ceil(source.maxY))+3
        func add(_ x:Int,_ y:Int) { let c = color(x,y);buckets[(c.0/16)*256+(c.1/16)*16+c.2/16,default:0] += 1 }
        for y in y0...y1 {
            if CGFloat(y) < source.minY-1 || CGFloat(y) > source.maxY+1 { for x in x0...x1 { add(x,y) } }
            else {
                for x in x0...min(x1,Int(source.minX)-2) { add(x,y) }
                let start = max(x0,Int(source.maxX)+2)
                if start <= x1 { for x in start...x1 { add(x,y) } }
            }
        }
        let key = buckets.max(by: {$0.value < $1.value})?.key ?? 4095
        return ((key/256)*16+8,((key/16)%16)*16+8,(key%16)*16+8)
    }
    func tightText(in normalized: CGRect, excluding masks: [CGRect] = []) -> CGRect? {
        let source = ScreenshotLayout.rect(normalized,in:size).intersection(CGRect(origin:.zero,size:size))
        guard !source.isNull,!source.isEmpty else { return nil }
        let bg = background(in:source),blocked = masks.map { ScreenshotLayout.rect($0,in:size) }.filter { $0.intersects(source) }
        let x0 = max(0,Int(source.minX)),x1 = min(width-1,Int(source.maxX)),y0 = max(0,Int(source.minY)),y1 = min(height-1,Int(source.maxY))
        var left = x1,right = x0,bottom = y1,top = y0,count = 0
        for y in y0...y1 { for x in x0...x1 {
            if !blocked.isEmpty && blocked.contains(where: {$0.contains(CGPoint(x:x,y:y))}) { continue }
            let c = color(x,y)
            if max(abs(c.0-bg.0),abs(c.1-bg.1),abs(c.2-bg.2)) > 38 { count += 1;left = min(left,x);right = max(right,x);bottom = min(bottom,y);top = max(top,y) }
        } }
        guard count >= 3 else { return nil }
        return CGRect(x:CGFloat(left)/size.width,y:CGFloat(bottom)/size.height,width:CGFloat(right-left+1)/size.width,height:CGFloat(top-bottom+1)/size.height)
    }
    func leadingIcon(in normalized: CGRect) -> (icon: CGRect, label: CGRect)? { affix(in: normalized,trailing: false) }
    func trailingIcon(in normalized: CGRect) -> (icon: CGRect, label: CGRect)? { affix(in: normalized,trailing: true) }
    private func affix(in normalized: CGRect, trailing: Bool) -> (icon: CGRect, label: CGRect)? {
        let source = ScreenshotLayout.rect(normalized, in: size).intersection(CGRect(origin: .zero,size: size))
        guard !source.isNull, source.width > source.height*1.5, source.height >= 3 else { return nil }
        let x0 = max(0,Int(source.minX)), x1 = min(width-1,Int(source.maxX)), y0 = max(0,Int(source.minY)), y1 = min(height-1,Int(source.maxY))
        func sample(_ x: Int,_ y: Int) -> (Int,Int,Int) { color(trailing ? x0+x1-x : x,y) }
        let bg = background(in:source)
        func ink(_ x: Int,_ y: Int) -> Bool { let c = sample(x,y); return max(abs(c.0-bg.0),abs(c.1-bg.1),abs(c.2-bg.2)) > 38 }
        var gapStart: Int?, hasInk = false
        var result: (icon: CGRect,label: CGRect)?
        for x in x0...min(x1, x0+Int(source.height*2.5)) {
            let occupied = (y0...y1).contains { ink(x,$0) }
            if occupied { hasInk = true; gapStart = nil }
            else if hasInk {
                if gapStart == nil { gapStart = x }
                if let start = gapStart, x-start+1 == Int(ceil(max(2,source.height*0.22))) {
                    var end = x+1
                    while end <= x1 && !(y0...y1).contains(where: { ink(end,$0) }) { end += 1 }
                    guard end < x1 else { continue }
                    func tight(_ left: Int,_ right: Int) -> CGRect {
                        var low = y1,high = y0
                        for xx in left...right { for yy in y0...y1 where ink(xx,yy) { low = min(low,yy); high = max(high,yy) } }
                        return CGRect(x: CGFloat(trailing ? x0+x1-right : left)/size.width,y: CGFloat(low)/size.height,width: CGFloat(right-left+1)/size.width,height: CGFloat(max(1,high-low+1))/size.height)
                    }
                    result = (tight(x0,max(x0,start-1)),tight(end,x1))
                }
            }
        }
        return result
    }
    func limits(source: CGRect, right: CGFloat, bottom: CGFloat) -> (right: CGFloat, bottom: CGFloat) {
        let source = source.intersection(CGRect(origin: .zero, size: size))
        guard !source.isEmpty, !source.isNull else { return (right,bottom) }
        let bg = background(in:source)
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
    var alignment: NSTextAlignment = .left
    var textInset: CGFloat = 2
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
        if let viewport = region.viewport {
            return containedPlacement(region:region,text:text,viewport:rect(viewport,in:size),size:size)
        }
        let canvas = CGRect(origin: .zero, size: size)
        var original = rect(region.bounds, in: size).insetBy(dx: -2, dy: -2).intersection(canvas)
        guard !original.isNull, original.width > 1, original.height > 1 else {
            return ScreenshotTextPlacement(frame: .zero, fontSize: 9, contentHeight: 0, scrolls: false)
        }
        // A centered navigation rail has several labels sharing a center but
        // different widths. Left-aligned sidebar items do not satisfy this test.
        let centerCandidate = region.bounds.midX*size.width < size.width*0.12 && ScreenshotTextFilter.isUILabel(region.text)
        let peers = centerCandidate ? regions.filter { other in
            abs(other.bounds.midX-region.bounds.midX)*size.width < max(2,region.lineHeight*size.height*0.3)
                && other.lineHeight/region.lineHeight > 0.75 && other.lineHeight/region.lineHeight < 1.3 && ScreenshotTextFilter.isUILabel(other.text)
        } : []
        let peerWidths = peers.map { $0.bounds.width*size.width },lefts = peers.map {$0.bounds.minX*size.width},rights = peers.map {$0.bounds.maxX*size.width}
        let widthSpread = (peerWidths.max() ?? 0)-(peerWidths.min() ?? 0)
        let centered = peers.count >= 3 && widthSpread > region.lineHeight*size.height*0.75
            && (lefts.max() ?? 0)-(lefts.min() ?? 0) > widthSpread*0.4 && (rights.max() ?? 0)-(rights.min() ?? 0) > widthSpread*0.4
        let gap: CGFloat = 4, padding: CGFloat = 4, widthPadding: CGFloat = 8
        let neighbors = regions.filter { $0.id != region.id }.map(\.bounds) + protectedBounds
        var right = canvas.maxX, below: CGFloat = 0
        let source = rect(region.bounds,in:size)
        for bounds in neighbors {
            let other = rect(bounds,in:size)
            if other.minX >= original.maxX-1 && abs(other.midY-original.midY) < max(other.height,original.height)*0.9 { right = min(right,other.minX-gap) }
        }
        if let limits = obstacles?.limits(source:source,right:right,bottom:source.minY) { right = min(right,limits.right) }
        let sourceWidth = region.text.components(separatedBy: .newlines).map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 100)]).size().width / 100
        }.max() ?? 1
        // Vision's vertical box includes language-dependent padding. Estimate
        // point size from both glyph width and height, so a 12 pt Chinese label
        // does not become a 20 pt English label after translation.
        let fromWidth = region.bounds.width * size.width / max(0.1, sourceWidth)
        let fromHeight = region.lineHeight * size.height * 1.25
        let preferred = (min(40, max(9, min(fromWidth, fromHeight * (ScreenshotTextFilter.isUILabel(region.text) ? 1.2 : 1)))) * 2).rounded(.down) / 2
        if original.height <= region.lineHeight * size.height * 1.6 + padding {
            // Short UI labels may need more horizontal space when Chinese
            // becomes English. Stop before other text in the same row.
            let natural = text.components(separatedBy: .newlines).map {
                (NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: preferred)]).size().width)
            }.max() ?? original.width
            let extraWidth = min(max(0, right - original.minX), min(max(original.width * 5, preferred * 12), ceil(natural) + widthPadding + 2))
            original.size.width = max(original.width, extraWidth)
        }
        if centered {
            let width = min(original.width,(peerWidths.max() ?? original.width)+8)
            original.origin.x = max(0,source.midX-width/2);original.size.width = width
        }
        for bounds in neighbors {
            let other = rect(bounds,in:size)
            if other.maxY <= original.minY+1 && min(other.maxX,original.maxX)-max(other.minX,original.minX) > 1 { below = max(below,other.maxY+gap) }
        }
        if let limits = obstacles?.limits(source:source,right:original.maxX,bottom:below) { below = max(below,limits.bottom) }
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
        return ScreenshotTextPlacement(frame:frame,fontSize:font,contentHeight:content,scrolls:content > frame.height+0.5,alignment:centered ? .center : .left)
    }
    private static func containedPlacement(region:ScreenshotTextRegion,text:String,viewport:CGRect,size:CGSize) -> ScreenshotTextPlacement {
        let clipped = viewport.intersection(CGRect(origin:.zero,size:size))
        guard !clipped.isNull,clipped.width > 4,clipped.height > 4 else {return ScreenshotTextPlacement(frame:.zero,fontSize:7,contentHeight:0,scrolls:true)}
        // Round inward: outward rounding can cross a one-pixel control border.
        let frame = CGRect(x:ceil(clipped.minX),y:ceil(clipped.minY),width:max(0,floor(clipped.maxX)-ceil(clipped.minX)),height:max(0,floor(clipped.maxY)-ceil(clipped.minY)))
        let source = rect(region.bounds,in:size),line = (region.fontLineHeight ?? region.lineHeight)*size.height
        let units = region.text.components(separatedBy:.newlines).map {NSAttributedString(string:$0,attributes:[.font:NSFont.systemFont(ofSize:100)]).size().width/100}.max() ?? 1
        let preferred = min(64,max(7,min(source.width/max(0.1,units),line*1.25)))
        // Match the source's scale. Small screenshots must not inherit a fixed
        // 9 pt lower bound that is larger than the control itself.
        // Preserve complete Latin words when they can fit at a readable size;
        // otherwise NSTextView may split "Translate" despite unused height.
        let words = text.split(whereSeparator:{!$0.isASCII || (!$0.isLetter && !$0.isNumber)}).map(String.init)
        let longestWord = words.max {a,b in
            NSAttributedString(string:a,attributes:[.font:NSFont.systemFont(ofSize:100)]).size().width < NSAttributedString(string:b,attributes:[.font:NSFont.systemFont(ofSize:100)]).size().width
        } ?? ""
        func wordWidth(_ font:CGFloat) -> CGFloat {NSAttributedString(string:longestWord,attributes:[.font:NSFont.systemFont(ofSize:font)]).size().width}
        // Measure at the actual font size: optical sizing is not proportional
        // to a 100 pt reference, and may otherwise break the final letter off.
        let keepWord = wordWidth(min(preferred,5.5))+0.5 <= frame.width-2
        var lower = min(preferred,5.5),upper = preferred
        // Navigation rows reserve one label line. Prefer a modest reduction
        // before wrapping into the inter-row space; retain wrapping when a
        // complete line would need unreadably small type.
        if region.fontLineHeight != nil,!text.contains("\n") {
            func singleWidth(_ font:CGFloat) -> CGFloat {NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:font)]).size().width}
            let readable = max(lower,preferred*0.8)
            if singleWidth(preferred) > frame.width-2,singleWidth(readable)+0.5 <= frame.width-2 {
                var lo = readable,hi = preferred
                for _ in 0..<10 {let mid = (lo+hi)/2;if singleWidth(mid)+0.5 <= frame.width-2 {lo = mid}else{hi = mid}}
                upper = lo
            }
        }
        for _ in 0..<10 {
            let middle = (lower+upper)/2
            if (!keepWord || wordWidth(middle)+0.5 <= frame.width-2) && measuredHeight(text,width:max(1,frame.width-2),fontSize:middle)+2 <= frame.height {lower = middle}else{upper = middle}
        }
        let content = measuredHeight(text,width:max(1,frame.width-2),fontSize:lower)+2
        let overflow = content > frame.height+0.1
        let height = min(frame.height,ceil(content))
        let y = region.centerVerticallyInViewport ? floor(frame.midY-height/2) : floor(frame.maxY-height)
        return ScreenshotTextPlacement(frame:CGRect(x:frame.minX,y:max(frame.minY,y),width:frame.width,height:height),fontSize:lower,contentHeight:content,scrolls:overflow,alignment:region.centeredInViewport ? .center : .left,textInset:1)
    }
    static func toolbarFrame(selection: CGRect, screen: CGRect, size: CGSize) -> CGRect {
        let x = max(screen.minX + 8, min(selection.midX - size.width / 2, screen.maxX - size.width - 8))
        let y = selection.minY - size.height - 8 >= screen.minY + 8 ? selection.minY - size.height - 8 : max(screen.minY + 8, selection.minY + 8)
        return CGRect(x: x, y: min(y, screen.maxY - size.height - 8), width: size.width, height: size.height)
    }
}
