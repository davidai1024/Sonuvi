// Sonuvi — GPL-3.0.
import AppKit

struct TranslationPart {
    let text: String
    var separator: String
    var attributes: [NSAttributedString.Key: Any] = [:]

    // Split at every explicit line break; retain separators locally rather than
    // relying on the model to reproduce them. Long lines are split at safe
    // boundaries without inventing a new line between the fragments.
    static func split(_ source: String, maximum: Int = 1800) -> [Self] {
        let chars = Array(source)
        let limit = max(1, maximum)
        var parts: [Self] = []
        var start = 0
        while start < chars.count {
            var end = start
            while end < chars.count && !chars[end].isNewline && end - start < limit { end += 1 }
            if end < chars.count && !chars[end].isNewline && end - start == limit {
                let lower = start + limit / 2
                if lower < end {
                    let candidates = (lower..<end).reversed()
                    if let boundary = candidates.first(where: { ".!?。！？；;".contains(chars[$0]) }) { end = boundary + 1 }
                    else if let boundary = candidates.first(where: { chars[$0].isWhitespace }) { end = boundary + 1 }
                }
            }
            let raw = String(chars[start..<end])
            var next = end
            while next < chars.count && chars[next].isNewline { next += 1 }
            let lineBreaks = String(chars[end..<next])
            let trailing = String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed())
            let body = String(raw.dropLast(trailing.count))
            if !body.isEmpty { parts.append(Self(text: body, separator: trailing + lineBreaks)) }
            else if let previous = parts.popLast() {
                parts.append(Self(text: previous.text, separator: previous.separator + raw + lineBreaks))
            }
            start = next
        }
        return parts
    }
}

/// Completed source fragments survive a retry; incomplete model responses do not.
@MainActor
final class TranslationWork {
    private(set) var parts: [TranslationPart]
    private(set) var completed: [String] = []
    private var batchLimit = 32
    private let leading: String
    private let source: String
    private var wholeOutput: String?
    private var wholeAttempted = false
    private var longChunks: [String]?
    private var longIndex = 0
    private var longCompleted = ""
    private var longWork: TranslationWork?
    var output: String { wholeOutput ?? (longChunks == nil ? prefix : longCompleted + (longWork?.output ?? "")) }
    var prefix: String { completed.isEmpty ? "" : leading + completed.enumerated().map { $0.element + parts[$0.offset].separator }.joined() }
    var attributedOutput: NSAttributedString? {
        guard hasStyles, !completed.isEmpty else { return nil }
        let result = NSMutableAttributedString(string: leading, attributes: parts.first?.attributes)
        for (index, value) in completed.enumerated() {
            result.append(NSAttributedString(string: value + parts[index].separator, attributes: parts[index].attributes))
        }
        return result
    }
    private let hasStyles: Bool
    // Split only at complete lines outside code fences. A single oversized
    // plain line is split at natural boundaries; oversized Markdown blocks
    // fall back to the original protected-fragment path.
    static func documentChunks(_ text: String, maximum: Int = 5000) -> [String]? {
        var result: [String] = []; var pending = ""; var fence: Character?
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let unit = line + (index + 1 < lines.count ? "\n" : "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.hasPrefix("```") ? Character("`") : (trimmed.hasPrefix("~~~") ? Character("~") : nil)
            if fence == nil && pending.count + unit.count > maximum && !pending.isEmpty {
                result.append(pending); pending = ""
            }
            pending += unit
            if let marker { if fence == nil { fence = marker } else if fence == marker { fence = nil } }
            if pending.count > maximum && fence == nil {
                guard !pending.contains("```") && !pending.contains("~~~"), pending.range(of: #"[*_\[\]`|]"#, options: .regularExpression) == nil else { return nil }
                let pieces = TranslationPart.split(pending, maximum: maximum)
                result += pieces.map { $0.text + $0.separator }; pending = ""
            }
        }
        if !pending.isEmpty { result.append(pending) }
        guard fence == nil, result.joined() == text else { return nil }
        return result
    }
    init(_ text: String, attributed: NSAttributedString? = nil) {
        source = text
        leading = attributed == nil ? "" : String(text.prefix(while: { $0.isWhitespace }))
        parts = attributed == nil ? MarkdownTranslation.parts(String(text.dropFirst(leading.count))) : TranslationPart.split(String(text.dropFirst(leading.count)))
        hasStyles = attributed?.string == text && attributed?.length != 0
        if hasStyles, let attributed {
            var offset = (leading as NSString).length
            var styled: [TranslationPart] = []
            for part in parts {
                let length = (part.text as NSString).length
                let sourceRange = NSRange(location: offset, length: length)
                var ranges: [(NSRange, [NSAttributedString.Key: Any])] = []
                attributed.enumerateAttributes(in: sourceRange) { attrs, range, _ in
                    let allowed: Set<NSAttributedString.Key> = [.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .paragraphStyle]
                    ranges.append((range, attrs.filter { allowed.contains($0.key) }))
                }
                for (i, item) in ranges.enumerated() {
                    let piece = (text as NSString).substring(with: item.0)
                    let trailing = String(piece.reversed().prefix(while: { $0.isWhitespace }).reversed())
                    let body = String(piece.dropLast(trailing.count))
                    styled.append(TranslationPart(text: body, separator: trailing + (i == ranges.count - 1 ? part.separator : ""), attributes: item.1))
                }
                offset += length + (part.separator as NSString).length
            }
            parts = styled
        }
    }

    // Preserve leading indentation and common list markers outside the model.
    private func prefixAndBody(_ text: String) -> (String, String) {
        let pattern = #"^([\t \u{3000}]*(?:(?:[-*+•]|[0-9]+[.)、]|[（(][0-9]+[）)])[\t ]+)?)"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return ("", text) }
        return (String(text[range]), String(text[range.upperBound...]))
    }

    func run(send: (String, @escaping @MainActor (String) -> Void) async throws -> String,
             onUpdate: @escaping @MainActor (String) -> Void,
             onProgress: @escaping @MainActor (Int, Int, Bool) -> Void) async throws -> String {
        var holdPreview = false
        func publish(_ value: String) { if !holdPreview { onUpdate(value) } }
        if let wholeOutput { return wholeOutput }
        if !hasStyles && source.count > 5000 && longChunks == nil && longIndex == 0 {
            if let chunks = Self.documentChunks(source), chunks.count > 1 { longChunks = chunks }
        }
        if let chunks = longChunks {
            while longIndex < chunks.count {
                try Task.checkCancellation()
                let child = longWork ?? TranslationWork(chunks[longIndex]); longWork = child
                let done = longCompleted; let current = longIndex
                let value = try await child.run(send: send, onUpdate: { onUpdate(done + $0) }, onProgress: { _, _, retry in onProgress(current + 1, chunks.count, retry) })
                longCompleted += value; longWork = nil; longIndex += 1
                onUpdate(longCompleted); onProgress(longIndex, chunks.count, false)
            }
            return longCompleted
        }
        // Most documents fit comfortably in the output budget. Give the model
        // complete sentences and context, then validate the Markdown before commit.
        if !wholeAttempted && !hasStyles && parts.count > 1 && source.count <= 5000 && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            wholeAttempted = true
            onProgress(1, 1, false)
            do {
                var response = ""
                for attempt in 0...1 {
                    do { response = try await send(source) { partial in onUpdate(partial) }; break }
                    catch TranslateError.retryable(let message) {
                        guard attempt == 0 else { wholeAttempted = false; throw TranslateError.message(message) }
                        onProgress(1, 1, true)
                        try await Task.sleep(nanoseconds: 800_000_000)
                        try Task.checkCancellation()
                    }
                }
                let trailing = String(source.reversed().prefix(while: { $0.isNewline }).reversed())
                let trimmedResponse = String(response.reversed().drop(while: { $0.isNewline }).reversed())
                let value = MarkdownTranslation.normalizeQuotedEmphasis(trimmedResponse + trailing)
                try Task.checkCancellation()
                if MarkdownTranslation.compatible(source, value) {
                    wholeOutput = value; onUpdate(value); onProgress(1, 1, false)
                    return value
                }
                holdPreview = true
            } catch TranslateError.outputLimit {
                // A model-specific output limit can be lower than our budget.
                // Discard the incomplete response and use the resumable path.
                holdPreview = true
            } catch {
                wholeAttempted = false
                throw error
            }
        }
        while completed.count < parts.count {
            try Task.checkCancellation()
            let index = completed.count
            var end = index
            var size = 0
            while end < parts.count && end - index < batchLimit {
                let nextSize = parts[end].text.count + 32
                if end > index && size + nextSize > 3600 { break }
                size += nextSize; end += 1
            }
            let group = Array(parts[index..<end])
            let extracted = group.map { prefixAndBody($0.text) }
            // Empty bodies (for example, a line containing only a bullet) are
            // handled individually, never sent as an empty translation request.
            if extracted[0].1.isEmpty {
                completed.append(extracted[0].0); publish(output); continue
            }
            if extracted.contains(where: { $0.1.isEmpty }) { end = index + 1 }
            let batch = Array(parts[index..<end])
            let fields = batch.map { prefixAndBody($0.text) }
            let nonce = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
            let markers = fields.indices.map { "⟦SONUVI_\(nonce)_\($0)⟧" }
            let request = fields.count == 1 ? fields[0].1 : zip(markers, fields).map { $0 + $1.1 }.joined(separator: "\n")
            let before = completed.isEmpty ? leading : prefix
            onProgress(index + 1, parts.count, false)
            do {
                var translated = ""
                for attempt in 0...1 {
                    do {
                        translated = try await send(request) { value in
                            if fields.count == 1 { publish(before + fields[0].0 + value) }
                        }
                        break
                    } catch TranslateError.retryable(let message) {
                        guard attempt == 0 else { throw TranslateError.message(message) }
                        publish(self.output); onProgress(index + 1, self.parts.count, true)
                        try await Task.sleep(nanoseconds: 800_000_000)
                        try Task.checkCancellation()
                    }
                }
                try Task.checkCancellation()
                let values: [String]?
                if fields.count == 1 { values = [translated] }
                else { values = Self.parseBatch(translated, markers: markers) }
                if let values, values.count == fields.count,
                   values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    for (field, value) in zip(fields, values) {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        let oneLine = trimmed.components(separatedBy: .newlines).joined(separator: " ")
                        completed.append(field.0 + (hasStyles ? oneLine : MarkdownTranslation.escapeTranslation(oneLine)))
                    }
                    publish(output); onProgress(completed.count, parts.count, false)
                } else if fields.count > 1 {
                    // Never guess alignment: retry smaller batches, keeping the
                    // remaining fragments batched instead of issuing one request per fragment.
                    batchLimit = max(1, fields.count / 2); publish(output)
                } else { throw TranslateError.message("模型未返回完整译文，请重试。") }
            } catch TranslateError.outputLimit {
                if fields.count > 1 {
                    batchLimit = max(1, fields.count / 2); publish(output)
                } else {
                    let part = parts[index]
                    guard part.text.count > 200 else { throw TranslateError.message("这段译文未能完整生成，请重试。") }
                    var smaller = TranslationPart.split(part.text, maximum: max(100, part.text.count / 2))
                    smaller = smaller.map { TranslationPart(text: $0.text, separator: $0.separator, attributes: part.attributes) }
                    if let last = smaller.popLast() { smaller.append(TranslationPart(text: last.text, separator: last.separator + part.separator, attributes: last.attributes)) }
                    parts.replaceSubrange(index...index, with: smaller)
                    publish(output)
                }
            }
        }
        if holdPreview { onUpdate(output) }
        return output
    }

    static func parseBatch(_ text: String, markers: [String]) -> [String]? {
        var cursor = text.startIndex
        var values: [String] = []
        for (i, marker) in markers.enumerated() {
            guard let range = text.range(of: marker, range: cursor..<text.endIndex),
                  text[cursor..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let start = range.upperBound
            if i + 1 < markers.count {
                guard let next = text.range(of: markers[i + 1], range: start..<text.endIndex) else { return nil }
                values.append(String(text[start..<next.lowerBound])); cursor = next.lowerBound
            } else { values.append(String(text[start...])); cursor = text.endIndex }
        }
        guard !values.contains(where: { $0.contains("⟦SONUVI_") }) else { return nil }
        return values
    }
}
