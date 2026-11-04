// Sonuvi — GPL-3.0. Region IDs, not model-generated coordinates, own alignment.
import AppKit

@MainActor
final class ScreenshotTranslationWork {
    let document: ScreenshotDocument
    private(set) var completed: [Int: String] = [:]
    private var fragments: [Int: [String]] = [:]
    init(document: ScreenshotDocument) { self.document = document }
    typealias Send = (String, Direction, @escaping @MainActor (String) -> Void) async throws -> String
    func run(send: Send, onUpdate: @escaping @MainActor ([Int: String]) -> Void,
             onProgress: @escaping @MainActor (Int, Int, Bool) -> Void) async throws {
        func commit(_ region: ScreenshotTextRegion, _ value: String) throws {
            let plain = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { throw TranslateError.message("部分译文未能完整返回，请重试。") }
            completed[region.id] = plain
            onUpdate(completed); onProgress(completed.count, document.regions.count, false)
        }
        func single(_ region: ScreenshotTextRegion) async throws {
            let parts = TranslationPart.split(region.text, maximum: 1800)
            var saved = fragments[region.id] ?? []
            while saved.count < parts.count {
                try Task.checkCancellation()
                let index = saved.count, part = parts[index]
                let prefix = saved.enumerated().map { $0.element + parts[$0.offset].separator }.joined()
                let value = try await TranslationRetry.run(onRetry: {
                    onProgress(self.completed.count, self.document.regions.count, true)
                }, operation: {
                    try await send(part.text, region.direction) { partial in
                        var visible = self.completed; visible[region.id] = prefix + partial
                        onUpdate(visible)
                    }
                })
                try Task.checkCancellation()
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslateError.message("部分译文未能完整返回，请重试。") }
                saved.append(value); fragments[region.id] = saved
            }
            try commit(region, saved.enumerated().map { $0.element + parts[$0.offset].separator }.joined())
        }
        do {
            for direction in [Direction.toChinese, .toEnglish] {
                var pending = document.regions.filter { $0.direction == direction && completed[$0.id] == nil }
                while !pending.isEmpty {
                    try Task.checkCancellation()
                    var batch: [ScreenshotTextRegion] = []; var size = 0
                    while let next = pending.first, batch.count < 8 {
                        if !batch.isEmpty && size + next.text.count > 4000 { break }
                        batch.append(pending.removeFirst()); size += next.text.count + 40
                    }
                    onProgress(completed.count, document.regions.count, false)
                    if batch.count == 1 { try await single(batch[0]); continue }
                    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
                    let markers = batch.indices.map { "⟦SONUVI_\(nonce)_\($0)⟧" }
                    let input = zip(markers, batch).map { $0 + $1.text }.joined(separator: "\n")
                    let response: String
                    do {
                        response = try await TranslationRetry.run(onRetry: {
                            onProgress(self.completed.count, self.document.regions.count, true)
                        }, operation: {
                            try await send(input, direction) { partial in
                                guard let pieces = TranslationWork.partialBatch(partial, markers: markers) else { return }
                                var visible = self.completed
                                for (index, piece) in pieces.enumerated() {
                                    visible[batch[index].id] = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                                onUpdate(visible)
                            }
                        })
                    } catch TranslateError.outputLimit {
                        for region in batch { try await single(region) }; continue
                    }
                    try Task.checkCancellation()
                    if let pieces = TranslationWork.parseBatch(response, markers: markers), pieces.count == batch.count,
                       pieces.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        for (region, piece) in zip(batch, pieces) { try commit(region, piece) }
                    } else {
                        // Never guess which translation belongs to which screen region.
                        onUpdate(completed)
                        for region in batch { try await single(region) }
                    }
                }
            }
        } catch {
            onUpdate(completed) // Incomplete previews never become completed/copyable text.
            throw error
        }
    }
}

enum ScreenshotPresentation: String, CaseIterable {
    case overlay = "原位置覆盖", window = "翻译窗口"
}
