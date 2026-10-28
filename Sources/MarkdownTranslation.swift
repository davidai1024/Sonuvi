// Sonuvi — GPL-3.0.
import AppKit

// Markdown syntax is owned by the client, never reconstructed by the model.
enum MarkdownTranslation {
    static func escapeTranslation(_ value: String) -> String {
        value.reduce(into: "") { output, character in
            if "\\*_~[]`|<>#!".contains(character) { output.append("\\") }
            output.append(character)
        }
    }
    static func parts(_ source: String) -> [TranslationPart] {
        var result: [TranslationPart] = []
        func literal(_ value: String) {
            guard !value.isEmpty else { return }
            if !result.isEmpty { result[result.count - 1].separator += value }
            else { result.append(TranslationPart(text: "", separator: value)) }
        }
        func prose(_ value: String) {
            let leading = String(value.prefix(while: { $0.isWhitespace }))
            literal(leading)
            let body = String(value.dropFirst(leading.count))
            result += TranslationPart.split(body)
        }
        var fence: Character?; var fenceLength = 0
        let lines = source.components(separatedBy: "\n")
        for raw in lines.enumerated() {
            let line = raw.element
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let fenceBody = trimmed.replacingOccurrences(of: #"^(?:>[ \t]*)+"#, with: "", options: .regularExpression)
            let run = fenceBody.prefix(while: { $0 == "`" || $0 == "~" })
            if let active = fence {
                literal(line)
                if run.count >= fenceLength && run.allSatisfy({ $0 == active }) && fenceBody.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
            } else if run.count >= 3 && Set(run).count == 1 {
                fence = run.first; fenceLength = run.count; literal(line)
            } else if ((line.hasPrefix("    ") || line.hasPrefix("\t")) && trimmed.range(of: #"^(?:[-+*]|[0-9]+[.)])[ \t]+"#, options: .regularExpression) == nil) || trimmed.range(of: #"^(?:[-*_][ \t]*){3,}$|^[=-]+$|^\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?$|^\[[^\]]+\]:"#, options: .regularExpression) != nil {
                literal(line)
            } else {
                // Block markers are kept outside all translation requests.
                let pattern = #"^[ \t]*(?:>[ \t]*)*(?:(?:#{1,6}[ \t]+)|(?:[-+*]|[0-9]+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?"#
                let range = line.range(of: pattern, options: .regularExpression)!
                literal(String(line[range])); let body = String(line[range.upperBound...])
                let chars = Array(body); var index = 0; var pending = ""
                func flush() { prose(pending); pending = "" }
                while index < chars.count {
                    let c = chars[index]
                    if c == "`" {
                        var end = index; while end < chars.count && chars[end] == "`" { end += 1 }
                        let delimiter = String(chars[index..<end]); let rest = String(chars[end...])
                        if let closing = rest.range(of: delimiter) {
                            flush(); let length = end - index + rest.distance(from: rest.startIndex, to: closing.upperBound)
                            literal(String(chars[index..<(index + length)])); index += length; continue
                        }
                    }
                    if c == "\\" { flush(); let end = min(chars.count, index + 2); literal(String(chars[index..<end])); index = end; continue }
                    if c == "[", (index > 0 && chars[index - 1] == "]") || (index + 1 < chars.count && chars[index + 1] == "^") {
                        if let end = chars[(index + 1)...].firstIndex(of: "]") { flush(); literal(String(chars[index...end])); index = end + 1; continue }
                    }
                    if c == "(", index > 0, chars[index - 1] == "]" {
                        var depth = 1; var end = index + 1
                        while end < chars.count && depth > 0 {
                            if chars[end] == "\\" { end = min(chars.count, end + 2); continue }
                            if chars[end] == "(" { depth += 1 }; if chars[end] == ")" { depth -= 1 }; end += 1
                        }
                        flush(); literal(String(chars[index..<end])); index = end; continue
                    }
                    if c == "<", let end = chars[(index + 1)...].firstIndex(of: ">") {
                        flush(); literal(String(chars[index...end])); index = end + 1; continue
                    }
                    if "*_~[]|!#".contains(c) { flush(); literal(String(c)) }
                    else { pending.append(c) }
                    index += 1
                }
                flush()
            }
            if raw.offset < lines.count - 1 { literal("\n") }
        }
        return result
    }

    // Convert the supported document semantics into Markdown once at import.
    // Fonts and colors from another app never become editor display colors.
    static func importText(_ text: String, styled: NSAttributedString?) -> String {
        guard let styled, styled.string == text else { return text }
        // Existing Markdown must remain byte-for-byte editable.
        if text.range(of: #"(?m)^\s*(?:#{1,6} |```|~~~|> )|\*\*|\[[^\]]+\]\("#, options: .regularExpression) != nil { return text }
        var output = ""
        var regularSizes: [CGFloat] = []
        styled.enumerateAttribute(.font, in: NSRange(location: 0, length: styled.length)) { value, _, _ in
            if let font = value as? NSFont, !font.fontDescriptor.symbolicTraits.contains(.bold) { regularSizes.append(font.pointSize) }
        }
        regularSizes.sort()
        let baseline = regularSizes.isEmpty ? CGFloat(12) : regularSizes[regularSizes.count / 2]
        let ns = text as NSString
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(location: offset, length: (line as NSString).length)
            if range.length > 0 {
                let font = styled.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
                let listPrefix = line.range(of: #"^[ \t]*(?:[-+*•]|[0-9]+[.)、])[ \t]+"#, options: .regularExpression)
                var fullyBold = true
                styled.enumerateAttribute(.font, in: range) { value, span, _ in
                    let piece = ns.substring(with: span).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty && (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) != true { fullyBold = false }
                }
                let isHeading = listPrefix == nil && fullyBold && (font?.pointSize ?? 0) >= max(15, baseline * 1.25)
                if isHeading { output += "## " }
                let prefixLength = listPrefix.map { (String(line[$0]) as NSString).length } ?? 0
                if prefixLength > 0 { output += ns.substring(with: NSRange(location: offset, length: prefixLength)) }
                let bodyRange = NSRange(location: offset + prefixLength, length: range.length - prefixLength)
                styled.enumerateAttributes(in: bodyRange) { attrs, span, _ in
                    let value = ns.substring(with: span)
                    let leading = String(value.prefix(while: { $0.isWhitespace }))
                    let rest = String(value.dropFirst(leading.count))
                    let trailing = String(rest.reversed().prefix(while: { $0.isWhitespace }).reversed())
                    let body = String(rest.dropLast(trailing.count))
                    let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                    let bold = traits.contains(.bold) && !isHeading; let italic = traits.contains(.italic)
                    let delimiter = (bold ? "**" : "") + (italic ? "_" : "")
                    let closing = (italic ? "_" : "") + (bold ? "**" : "")
                    let escaped = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
                    if let url = attrs[.link] { output += leading + "[" + escaped + "](" + String(describing: url) + ")" + trailing }
                    else { output += leading + (body.isEmpty ? "" : delimiter + escaped + closing) + trailing }
                }
            }
            offset += range.length
            if offset < ns.length { output += "\n"; offset += 1 }
        }
        return output
    }
}
