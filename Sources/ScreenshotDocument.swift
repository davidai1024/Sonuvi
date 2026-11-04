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
    var text: String { regions.map(\.text).joined(separator: "\n\n") }
    init(lines: [ScreenshotTextLine]) {
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
    init(regions: [ScreenshotTextRegion]) { self.regions = regions }
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
    static func placement(region: ScreenshotTextRegion, text: String, regions: [ScreenshotTextRegion], size: CGSize) -> ScreenshotTextPlacement {
        let canvas = CGRect(origin: .zero, size: size)
        var original = rect(region.bounds, in: size).insetBy(dx: -2, dy: -2).intersection(canvas)
        guard !original.isNull, original.width > 1, original.height > 1 else {
            return ScreenshotTextPlacement(frame: .zero, fontSize: 9, contentHeight: 0, scrolls: false)
        }
        let gap: CGFloat = 3, padding: CGFloat = 4
        let sourceWidth = region.text.components(separatedBy: .newlines).map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 100)]).size().width / 100
        }.max() ?? 1
        // Vision's vertical box includes language-dependent padding. Estimate
        // point size from both glyph width and height, so a 12 pt Chinese label
        // does not become a 20 pt English label after translation.
        let fromWidth = region.bounds.width * size.width / max(0.1, sourceWidth)
        let fromHeight = region.lineHeight * size.height * 1.25
        let preferred = min(40, max(8, min(fromWidth, fromHeight)))
        if original.height <= region.lineHeight * size.height * 1.6 + padding {
            // Short UI labels may need more horizontal space when Chinese
            // becomes English. Stop before other text in the same row.
            var right = canvas.maxX
            for other in regions where other.id != region.id {
                let otherRect = rect(other.bounds, in: size)
                let overlap = min(otherRect.maxY, original.maxY) - max(otherRect.minY, original.minY)
                if otherRect.minX >= original.maxX - 1 && overlap > 1 { right = min(right, otherRect.minX - gap) }
            }
            let natural = text.components(separatedBy: .newlines).map {
                (NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: preferred)]).size().width)
            }.max() ?? original.width
            let extraWidth = min(max(0, right - original.minX), min(max(original.width * 5, preferred * 12), natural + padding))
            original.size.width = max(original.width, extraWidth)
        }
        var below: CGFloat = 0
        for other in regions where other.id != region.id {
            let otherRect = rect(other.bounds, in: size)
            let overlap = min(otherRect.maxX, original.maxX) - max(otherRect.minX, original.minX)
            if otherRect.maxY <= original.minY + 1 && overlap > 1 { below = max(below, otherRect.maxY + gap) }
        }
        // Expand down only into empty space, never over the next text block.
        let maximumHeight = max(original.height, min(original.maxY - below, max(original.height * 2.5, 48)))
        var lower: CGFloat = min(9, preferred), upper = preferred
        for _ in 0..<8 {
            let middle = (lower + upper) / 2
            if measuredHeight(text, width: original.width - padding, fontSize: middle) + padding <= maximumHeight { lower = middle }
            else { upper = middle }
        }
        let font = lower
        let content = measuredHeight(text, width: original.width - padding, fontSize: font) + padding
        let height = max(original.height, min(maximumHeight, content))
        let frame = CGRect(x: original.minX, y: original.maxY - height, width: original.width, height: height).intersection(canvas)
        return ScreenshotTextPlacement(frame: frame, fontSize: font, contentHeight: content, scrolls: content > frame.height + 0.5)
    }
    static func toolbarFrame(selection: CGRect, screen: CGRect, size: CGSize) -> CGRect {
        let x = max(screen.minX + 8, min(selection.midX - size.width / 2, screen.maxX - size.width - 8))
        let y = selection.minY - size.height - 8 >= screen.minY + 8 ? selection.minY - size.height - 8 : max(screen.minY + 8, selection.minY + 8)
        return CGRect(x: x, y: min(y, screen.maxY - size.height - 8), width: size.width, height: size.height)
    }
}
