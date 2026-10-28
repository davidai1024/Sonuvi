// Sonuvi — GPL-3.0.
import AppKit
import ApplicationServices

enum RichText {
    static func write(_ text: String, styled: NSAttributedString?, to board: NSPasteboard) {
        let item = NSPasteboardItem(); item.setString(text, forType: .string)
        if let styled, styled.string == text,
           let data = try? styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(data, forType: .rtf)
        }
        board.clearContents(); board.writeObjects([item])
    }
    static func normalizeAX(_ value: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: value.string)
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, range, _ in
            var mapped = attrs.filter { [.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .paragraphStyle].contains($0.key) }
            if let info = attrs[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any],
               let name = info[kAXFontNameKey.takeUnretainedValue() as String] as? String,
               let size = info[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber,
               let font = NSFont(name: name, size: CGFloat(truncating: size)) { mapped[.font] = font }
            if let raw = attrs[NSAttributedString.Key(kAXForegroundColorTextAttribute.takeUnretainedValue() as String)], CFGetTypeID(raw as CFTypeRef) == CGColor.typeID { mapped[.foregroundColor] = NSColor(cgColor: raw as! CGColor) }
            if let raw = attrs[NSAttributedString.Key(kAXBackgroundColorTextAttribute.takeUnretainedValue() as String)], CFGetTypeID(raw as CFTypeRef) == CGColor.typeID { mapped[.backgroundColor] = NSColor(cgColor: raw as! CGColor) }
            if let underline = attrs[NSAttributedString.Key(kAXUnderlineTextAttribute.takeUnretainedValue() as String)] as? NSNumber { mapped[.underlineStyle] = underline }
            if let strike = attrs[NSAttributedString.Key(kAXStrikethroughTextAttribute.takeUnretainedValue() as String)] as? Bool, strike { mapped[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.addAttributes(mapped, range: range)
        }
        return result
    }
    static func fromPasteboard(_ board: NSPasteboard) -> NSAttributedString? {
        guard let plain = board.string(forType: .string),
              let data = board.data(forType: .rtf), data.count <= 16_000_000,
              let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { return nil }
        return aligned(value, to: plain)
    }

    // Word can use CR or CRLF in one clipboard representation and LF in
    // another, or include the final paragraph mark only in the RTF. Preserve
    // its attributes while matching exactly the text the application displays.
    static func aligned(_ value: NSAttributedString, to plain: String) -> NSAttributedString? {
        if value.string == plain { return value }
        let source = value.string as NSString, target = plain as NSString
        let result = NSMutableAttributedString(string: "")
        var i = 0, j = 0
        func lineBreak(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 }
        func advance(_ s: NSString, _ index: Int) -> Int {
            index + ((s.character(at: index) == 13 && index + 1 < s.length && s.character(at: index + 1) == 10) ? 2 : 1)
        }
        while i < source.length && j < target.length {
            let a = source.character(at: i), b = target.character(at: j)
            if lineBreak(a) && lineBreak(b) {
                let next = advance(target, j)
                result.append(NSAttributedString(string: target.substring(with: NSRange(location: j, length: next - j)), attributes: value.attributes(at: i, effectiveRange: nil)))
                i = advance(source, i); j = next
            } else if a == b {
                let start = i, targetStart = j
                while i < source.length && j < target.length && source.character(at: i) == target.character(at: j) && !lineBreak(source.character(at: i)) { i += 1; j += 1 }
                result.append(value.attributedSubstring(from: NSRange(location: start, length: i - start)))
                assert(i - start == j - targetStart)
            } else { return nil }
        }
        // An extra terminal paragraph marker does not change the content.
        if i < source.length && j == target.length && lineBreak(source.character(at: i)) && advance(source, i) == source.length { i = source.length }
        if j < target.length && i == source.length && lineBreak(target.character(at: j)) && advance(target, j) == target.length {
            let attrs = value.length > 0 ? value.attributes(at: value.length - 1, effectiveRange: nil) : [:]
            result.append(NSAttributedString(string: target.substring(from: j), attributes: attrs)); j = target.length
        }
        return i == source.length && j == target.length && result.string == plain ? result : nil
    }
}
