// Sonuvi — GPL-3.0. Read-only projection and incremental native text updates.
import AppKit

/// Reuse completed lines; an appended token usually changes only the last line.
/// Source-position maps are built only when editing or copying a selection.
final class MarkdownDisplayProjection {
    private struct Line {
        let source: String
        let before: MarkdownFence?
        let after: MarkdownFence?
        let plain: String
    }
    private var lines: [Line] = []
    private var markdown: String?
    private(set) var plain = ""
    private(set) var parsedLines = 0

    func update(_ value: String) -> String {
        guard markdown != value else { return plain }
        let source = value.components(separatedBy: "\n")
        var next: [Line] = []; next.reserveCapacity(source.count)
        var fence: MarkdownFence?
        for (index, line) in source.enumerated() {
            let unit = line + (index + 1 < source.count ? "\n" : "")
            if index < lines.count, lines[index].source == unit, lines[index].before == fence {
                next.append(lines[index])
            } else {
                let document = MarkdownDocument(unit, trackingPositions: false, initialFence: fence)
                parsedLines += 1
                next.append(Line(source: unit, before: fence, after: document.endingFence, plain: document.plain))
            }
            fence = next[index].after
        }
        lines = next; markdown = value; plain = next.map(\.plain).joined()
        return plain
    }
}

enum StreamingTextUpdate {
    /// Replace only the changed tail, leaving existing glyphs and selection intact.
    /// UTF-16 boundaries are widened when necessary to preserve surrogate pairs.
    @discardableResult
    static func apply(_ value: String, to storage: NSTextStorage) -> NSRange? {
        let old = storage.string as NSString, incoming = value as NSString
        guard old != incoming else { return nil }
        var prefix = 0
        let limit = min(old.length, incoming.length)
        while prefix < limit && old.character(at: prefix) == incoming.character(at: prefix) { prefix += 1 }
        func isLowSurrogate(_ c: unichar) -> Bool { (0xDC00...0xDFFF).contains(c) }
        if prefix > 0, (prefix < old.length && isLowSurrogate(old.character(at: prefix))) || (prefix < incoming.length && isLowSurrogate(incoming.character(at: prefix))) { prefix -= 1 }
        storage.replaceCharacters(in: NSRange(location: prefix, length: old.length - prefix), with: incoming.substring(from: prefix))
        return NSRange(location: prefix, length: incoming.length - prefix)
    }
}
