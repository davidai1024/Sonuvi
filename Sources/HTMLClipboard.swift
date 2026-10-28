// Convert copied webpage fragments without loading remote resources.
import Foundation
import libxml2

enum HTMLClipboard {
    static func markdown(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= 4_000_000 else { return nil }
        let options = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_COMPACT.rawValue)
        guard let doc = data.withUnsafeBytes({ bytes in
            htmlReadMemory(bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), nil, "UTF-8", options)
        }) else { return nil }
        defer { xmlFreeDoc(doc) }
        func attr(_ node: xmlNodePtr, _ key: String) -> String? {
            guard let value = key.withCString({ xmlGetProp(node, UnsafePointer<xmlChar>(OpaquePointer($0))) }) else { return nil }
            defer { xmlFree?(value) }
            return String(cString: value)
        }
        func escape(_ text: String) -> String {
            var result = ""
            for c in text { if "\\*_~[]`".contains(c) { result.append("\\") }; result.append(c) }
            return result
        }
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func render(_ node: xmlNodePtr?, depth: Int = 0) -> String {
            guard let node else { return "" }
            if node.pointee.type == XML_TEXT_NODE {
                guard let value = node.pointee.content else { return "" }
                let text = String(cString: value).replacingOccurrences(of: "\u{00a0}", with: " ")
                    .replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
                return escape(text)
            }
            guard node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name else { return "" }
            let tag = String(cString: name).lowercased()
            if ["head", "style", "script", "svg", "img", "noscript"].contains(tag) { return "" }
            if tag == "br" { return "\n" }
            var children = "", child = node.pointee.children
            if tag == "ul" || tag == "ol" {
                var number = Int(attr(node, "start") ?? "1") ?? 1
                while let item = child {
                    if item.pointee.type == XML_ELEMENT_NODE, let name = item.pointee.name, String(cString: name).lowercased() == "li" {
                        let content = trim(render(item, depth: depth + 1))
                        if !content.isEmpty {
                            let marker = tag == "ol" ? "\(number). " : "- "
                            children += String(repeating: "  ", count: depth) + marker + content + "\n"
                            number += 1
                        }
                    }
                    child = item.pointee.next
                }
                return "\n" + children + "\n"
            }
            while let item = child { children += render(item, depth: depth); child = item.pointee.next }
            let body = trim(children)
            if tag == "a", !body.isEmpty, let href = attr(node, "href"),
               let url = URL(string: href), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                return "[" + body + "](" + href.replacingOccurrences(of: ")", with: "%29") + ")"
            }
            if ["strong", "b"].contains(tag), !body.isEmpty { return "**" + body + "**" }
            if ["em", "i"].contains(tag), !body.isEmpty { return "_" + body + "_" }
            if tag == "code", !body.isEmpty { return "`" + body + "`" }
            if tag == "li" { return body }
            if tag.count == 2, tag.first == "h", let n = Int(String(tag.last!)), (1...6).contains(n), !body.isEmpty {
                return "\n\n" + String(repeating: "#", count: n) + " " + body + "\n\n"
            }
            if tag == "blockquote", !body.isEmpty { return "\n\n> " + body.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" }
            if ["p", "div", "section", "article", "pre"].contains(tag), !body.isEmpty { return "\n\n" + body + "\n\n" }
            return children
        }
        let output = trim(render(xmlDocGetRootElement(doc)))
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return output.isEmpty ? nil : output
    }
}
