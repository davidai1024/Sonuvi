// Sonuvi — GPL-3.0.
import Foundation

struct TranslationPart {
    let text: String
    let separator: String
    static func split(_ source: String, maximum: Int = 1800) -> [Self] {
        let chars = Array(source)
        var parts: [Self] = []; var start = 0
        let maximum = max(1, maximum)
        while start < chars.count {
            var end = min(start + maximum, chars.count)
            if end < chars.count {
                let lower = start + maximum / 2
                // Prefer a paragraph, then a sentence, then a word boundary.
                let candidates = Array(lower..<end).reversed()
                if let boundary = candidates.first(where: { chars[$0] == "\n" }) { end = boundary + 1 }
                else if let boundary = candidates.first(where: { ".!?。！？；;".contains(chars[$0]) }) { end = boundary + 1 }
                else if let boundary = candidates.first(where: { chars[$0].isWhitespace }) { end = boundary + 1 }
            }
            while end < chars.count && chars[end].isWhitespace { end += 1 }
            let raw = String(chars[start..<end])
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let trailing = String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed())
            if !text.isEmpty { parts.append(Self(text: text, separator: trailing)) }
            else if let previous = parts.popLast() { parts.append(Self(text: previous.text, separator: previous.separator + raw)) }
            start = end
        }
        return parts
    }
}

/// Only fully completed parts survive a retry. A failed/cancelled run is never
/// cached as a complete translation. All callbacks belong to its caller's task.
@MainActor
final class TranslationWork {
    private(set) var parts: [TranslationPart]
    private(set) var completed: [String] = []
    var output: String {
        completed.enumerated().map { index, value in value + joiner(index) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var prefix: String { completed.enumerated().map { $0.element + joiner($0.offset) }.joined() }
    private func joiner(_ index: Int) -> String {
        let separator = parts[index].separator
        return separator.isEmpty && index + 1 < parts.count ? "\n" : separator
    }
    init(_ text: String) { parts = TranslationPart.split(text) }
    func run(send: (String, @escaping @MainActor (String) -> Void) async throws -> String,
             onUpdate: @escaping @MainActor (String) -> Void,
             onProgress: @escaping @MainActor (Int, Int, Bool) -> Void) async throws -> String {
        while completed.count < parts.count {
            try Task.checkCancellation()
            let index = completed.count; let part = parts[index]; let prefix = self.prefix
            onProgress(index + 1, parts.count, false)
            do {
                var translated = ""
                for attempt in 0...1 {
                    do {
                        translated = try await send(part.text) { value in onUpdate(prefix + value) }
                        break
                    } catch TranslateError.retryable(let message) {
                        guard attempt == 0 else { throw TranslateError.message(message) }
                        onUpdate(self.output); onProgress(index + 1, self.parts.count, true)
                        try await Task.sleep(nanoseconds: 800_000_000)
                        try Task.checkCancellation()
                    }
                }
                try Task.checkCancellation()
                completed.append(translated.trimmingCharacters(in: .whitespacesAndNewlines))
                onUpdate(output)
            } catch TranslateError.outputLimit {
                // An unusually expansive translation gets smaller requests,
                // rather than asking the user to shorten their selection.
                guard part.text.count > 200 else { throw TranslateError.message("这段译文未能完整生成，请重试。") }
                var smaller = TranslationPart.split(part.text, maximum: max(100, part.text.count / 2))
                if let last = smaller.popLast() { smaller.append(TranslationPart(text: last.text, separator: last.separator + part.separator)) }
                parts.replaceSubrange(index...index, with: smaller)
                onUpdate(output)
            }
        }
        return output
    }
}
