// Sonuvi — GPL-3.0.
import AppKit

// Rich clipboard is for document editors; Markdown remains available as text.
enum MarkdownRichExport {
    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "")
        let lines = markdown.components(separatedBy: "\n")
        var fence: Character?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")), let mark = trimmed.first {
                if fence == nil { fence = mark } else if fence == mark { fence = nil }
                continue
            }
            let header = line.range(of: #"^\s{0,3}#{1,6}[ \t]+"#, options: .regularExpression)
            let list = line.range(of: #"^([ \t]*)(?:[-+*]|[0-9]+[.)])[ \t]+"#, options: .regularExpression)
            let quote = line.range(of: #"^\s{0,3}>[ \t]?"#, options: .regularExpression)
            var body = line, prefix = ""
            if fence == nil, let header { body = String(line[header.upperBound...]) }
            else if fence == nil, let list {
                let marker = String(line[list]); let stripped = marker.trimmingCharacters(in: .whitespaces)
                let indent = String(marker.prefix(while: { $0 == " " || $0 == "\t" }))
                prefix = indent + (stripped.first?.isNumber == true ? stripped : "•") + " "
                body = String(line[list.upperBound...])
            } else if fence == nil, let quote { prefix = "│ "; body = String(line[quote.upperBound...]) }
            if !prefix.isEmpty { out.append(NSAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: 14)])) }
            let size: CGFloat = header == nil ? 14 : 20
            if fence != nil {
                out.append(NSAttributedString(string: body, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)]))
            } else if let parsed = try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in parsed.runs {
                    let intent = run.inlinePresentationIntent
                    let bold = header != nil || intent?.contains(.stronglyEmphasized) == true
                    let italic = intent?.contains(.emphasized) == true
                    var font = intent?.contains(.code) == true ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
                    if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    var attrs: [NSAttributedString.Key: Any] = [.font: font]
                    if let link = run.link { attrs[.link] = link; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if intent?.contains(.strikethrough) == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
                }
            } else { out.append(NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: size)])) }
            if index < lines.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }
}
