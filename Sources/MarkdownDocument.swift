// Sonuvi — GPL-3.0.
import AppKit

// A plain-text projection of a Markdown document with UTF-16 source positions.
// The original document remains the source of truth during display and editing.
struct MarkdownDocument {
    let markdown: String
    let plain: String
    private let positions: [NSRange]
    private let codePositions: [Bool]

    init(_ markdown: String) {
        self.markdown = markdown
        var text = "", locations: [NSRange] = [], codeFlags: [Bool] = []
        func append(_ value: String, source: NSRange, original: String, code: Bool = false) {
            let raw = Array(original.utf16), visible = Array(value.utf16)
            var deleted = Set<Int>(), inserted = Set<Int>()
            if raw != visible {
                for change in visible.difference(from: raw) {
                    switch change { case .remove(let i, _, _): deleted.insert(i); case .insert(let i, _, _): inserted.insert(i) }
                }
            }
            var cursor = 0
            for index in visible.indices {
                let start = cursor
                while cursor < raw.count && deleted.contains(cursor) { cursor += 1 }
                if !inserted.contains(index) && cursor < raw.count { cursor += 1 }
                locations.append(NSRange(location: source.location + start, length: cursor - start)); codeFlags.append(code)
            }
            text += value
        }
        var offset = 0, fence: Character?, fenceLength = 0
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length
            defer { offset += length + (index < lines.count - 1 ? 1 : 0) }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let fenceBody = trimmed.replacingOccurrences(of: #"^(?:>[ \t]*)+"#, with: "", options: .regularExpression)
            let run = fenceBody.prefix(while: { $0 == "`" || $0 == "~" })
            if let active = fence, run.count >= fenceLength, run.allSatisfy({ $0 == active }), fenceBody.dropFirst(run.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fence = nil; continue
            }
            if fence == nil && run.count >= 3 && Set(run).count == 1 { fence = run.first; fenceLength = run.count; continue }
            let indentedCode = (line.hasPrefix("    ") || line.hasPrefix("\t")) && trimmed.range(of: #"^(?:[-+*]|[0-9]+[.)])[ \t]+"#, options: .regularExpression) == nil
            if fence != nil || indentedCode {
                append(line, source: NSRange(location: offset, length: length), original: line, code: true)
            } else if trimmed.range(of: #"^(?:[-*_][ \t]*){3,}$|^[=-]+$|^\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?$|^\[[^\]]+\]:"#, options: .regularExpression) == nil {
                let prefix = line.range(of: #"^[ \t]*(?:>[ \t]*)*(?:(?:#{1,6}[ \t]+)|(?:[-+*]|[0-9]+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?"#, options: .regularExpression)!
                let body = String(line[prefix.upperBound...]), prefixLength = (String(line[prefix]) as NSString).length
                let indentation = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                if !indentation.isEmpty { append(indentation, source: NSRange(location: offset, length: (indentation as NSString).length), original: indentation) }
                if let parsed = try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true)) {
                    for span in parsed.runs {
                        let value = String(parsed[span.range].characters)
                        if let position = span.markdownSourcePosition, let sourceIndices = Range<String.Index>(position, in: body) {
                            let source = NSRange(sourceIndices, in: body)
                            let raw = (body as NSString).substring(with: source)
                            // Table columns become ordinary tab-separated text.
                            let shown = span.inlinePresentationIntent?.contains(.code) == true ? value : value.replacingOccurrences(of: "|", with: "\t")
                            append(shown, source: NSRange(location: offset + prefixLength + source.location, length: source.length), original: raw, code: span.inlinePresentationIntent?.contains(.code) == true)
                        } else {
                            append(value, source: NSRange(location: offset + prefixLength, length: (body as NSString).length), original: body)
                        }
                    }
                } else { append(body, source: NSRange(location: offset + prefixLength, length: (body as NSString).length), original: body) }
            }
            if index < lines.count - 1 { append("\n", source: NSRange(location: offset + length, length: 1), original: "\n") }
        }
        plain = text; positions = locations; codePositions = codeFlags
    }

    private func sourceRange(_ range: NSRange) -> NSRange? {
        guard range.location >= 0, range.length >= 0, range.location <= positions.count, range.length <= positions.count - range.location else { return nil }
        if range.length == 0 {
            let insertion = range.location == 0 ? (positions.first?.location ?? (markdown as NSString).length) : NSMaxRange(positions[range.location - 1])
            return NSRange(location: insertion, length: 0)
        }
        let start = positions[range.location].location, end = NSMaxRange(positions[NSMaxRange(range) - 1])
        return NSRange(location: start, length: max(0, end - start))
    }

    func replacing(_ range: NSRange, withMarkdown value: String, entireDocument: Bool = false) -> String {
        guard var raw = sourceRange(range) else { return markdown }
        let source = markdown as NSString
        if entireDocument && range.location == 0 && range.length == positions.count { return value }
        // Removing an entire styled word must not leave visible empty delimiters.
        if value.isEmpty {
            for delimiter in ["***", "**", "__", "~~", "*", "_", "`"] {
                let size = (delimiter as NSString).length
                if raw.location >= size && NSMaxRange(raw) + size <= source.length,
                   source.substring(with: NSRange(location: raw.location - size, length: size)) == delimiter,
                   source.substring(with: NSRange(location: NSMaxRange(raw), length: size)) == delimiter {
                    raw = NSRange(location: raw.location - size, length: raw.length + size * 2); break
                }
            }
        }
        return source.replacingCharacters(in: raw, with: value)
    }

    func editingPlain(_ updated: String) -> String {
        guard updated != plain else { return markdown }
        if updated.isEmpty { return "" }
        let old = Array(plain), new = Array(updated)
        var start = 0, tail = 0
        while start < min(old.count, new.count) && old[start] == new[start] { start += 1 }
        while tail < min(old.count - start, new.count - start) && old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let location = (String(old.prefix(start)) as NSString).length
        let length = (String(old[start..<(old.count - tail)]) as NSString).length
        let inserted = String(new[start..<(new.count - tail)])
        let range = NSRange(location: location, length: length)
        let code = length > 0 ? codePositions[location..<NSMaxRange(range)].allSatisfy { $0 } : (location > 0 && codePositions[location - 1])
        return replacing(range, withMarkdown: code ? inserted : MarkdownTranslation.escapeTranslation(inserted))
    }

    func fragment(_ range: NSRange) -> String? {
        guard var raw = sourceRange(range), range.length > 0 else { return nil }
        if range.location == 0 && range.length == positions.count { return markdown }
        let source = markdown as NSString
        for delimiter in ["***", "**", "__", "~~", "*", "_", "`"] {
            let size = (delimiter as NSString).length
            if raw.location >= size && NSMaxRange(raw) + size <= source.length,
               source.substring(with: NSRange(location: raw.location - size, length: size)) == delimiter,
               source.substring(with: NSRange(location: NSMaxRange(raw), length: size)) == delimiter {
                raw = NSRange(location: raw.location - size, length: raw.length + size * 2); break
            }
        }
        return source.substring(with: raw)
    }
}

enum MarkdownClipboard {
    static let backingType = NSPasteboard.PasteboardType("org.sonuvi.markdown")
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")
    static func read(_ board: NSPasteboard) -> String? {
        guard let text = board.string(forType: .string) else { return nil }
        for type in [backingType, markdownType] {
            if let markdown = board.string(forType: type), markdown.utf8.count <= 16_000_000,
               markdown == text || MarkdownDocument(markdown).plain == text { return markdown }
        }
        return MarkdownTranslation.importText(text, styled: RichText.fromPasteboard(board))
    }
    static func write(_ markdown: String, to board: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(markdown, forType: .string)
        let rich = MarkdownRichExport.render(markdown)
        if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(rtf, forType: .rtf)
        }
        item.setString(markdown, forType: backingType); item.setString(markdown, forType: markdownType)
        board.clearContents(); board.writeObjects([item])
    }
}
