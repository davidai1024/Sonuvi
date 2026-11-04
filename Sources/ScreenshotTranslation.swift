// Sonuvi — GPL-3.0. Region IDs, not model-generated coordinates, own alignment.
import AppKit

@MainActor
final class ScreenshotTranslationWork {
    let document: ScreenshotDocument
    private(set) var completed: [Int: String] = [:]
    private(set) var requestedNetwork = false
    private var fragments: [Int: [String]] = [:]
    let forcedDirection: Direction?
    let concurrency: Int
    let batchLimit: Int
    init(document: ScreenshotDocument, direction: Direction? = nil, cache: [String: String] = [:], concurrency: Int = 3, batchLimit: Int = 12) {
        self.document = document; self.forcedDirection = direction; self.concurrency = max(1,min(3,concurrency)); self.batchLimit = max(1,min(12,batchLimit))
        for region in document.regions {
            if !ScreenshotTranslationRules.needsTranslation(region.text) || (direction != nil && region.direction != direction) {
                completed[region.id] = region.text
            } else if let value = cache[Self.cacheKey(region.text, direction: direction ?? region.direction)] { completed[region.id] = value }
        }
    }
    static func cacheKey(_ text: String, direction: Direction) -> String { direction.rawValue + "\n" + text }
    typealias Send = @MainActor (String, Direction, @escaping @MainActor (String) -> Void) async throws -> String
    func run(send: @escaping Send, onUpdate: @escaping @MainActor ([Int: String]) -> Void,
             onProgress: @escaping @MainActor (Int, Int, Bool) -> Void,
             onCommit: @escaping @MainActor ([Int: String]) -> Void = { _ in }) async throws {
        func commit(_ region: ScreenshotTextRegion, _ value: String, publish: Bool = true) throws {
            let plain = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { throw TranslateError.message("部分译文未能完整返回，请重试。") }
            for alias in document.regions where alias.text == region.text && (forcedDirection ?? alias.direction) == (forcedDirection ?? region.direction) {
                completed[alias.id] = plain
            }
            if publish { onUpdate(completed); onCommit(completed); onProgress(completed.count, document.regions.count, false) }
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
                    try await send(part.text, self.forcedDirection ?? region.direction) { partial in
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
        @MainActor func batch(_ batch: [ScreenshotTextRegion], direction: Direction) async throws {
            onProgress(completed.count, document.regions.count, false)
            if batch.count == 1 { try await single(batch[0]); return }
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
            let markers = batch.indices.map { "⟦SONUVI_\(nonce)_\($0)⟧" }
            let input = zip(markers, batch).map { $0 + $1.text }.joined(separator: "\n")
            let response: String
            var firstDelivered = false
            do {
                response = try await TranslationRetry.run(onRetry: {
                    onProgress(self.completed.count, self.document.regions.count, true)
                }, operation: {
                    try await send(input, direction) { partial in
                        guard !Task.isCancelled,let pieces = TranslationWork.partialBatch(partial,markers:markers) else { return }
                        // The next exact marker closes the first slot. Reveal this
                        // complete slot once; never paint unfinished words or markers.
                        if !firstDelivered,pieces.count > 1 {
                            let first = pieces[0].trimmingCharacters(in:.whitespacesAndNewlines)
                            if !first.isEmpty,!first.contains("⟦SONUVI_") { try? commit(batch[0],first);firstDelivered = true }
                        }
                        var visible = self.completed
                        for (index, piece) in pieces.enumerated() {
                            visible[batch[index].id] = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        onUpdate(visible)
                    }
                })
            } catch TranslateError.outputLimit {
                for region in batch where completed[region.id] == nil { try await single(region) }; return
            }
            try Task.checkCancellation()
            if let pieces = TranslationWork.parseBatch(response, markers: markers), pieces.count == batch.count,
               pieces.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                for (region, piece) in zip(batch, pieces) { try commit(region,piece,publish:false) }
                onUpdate(completed);onCommit(completed);onProgress(completed.count,document.regions.count,false)
            } else {
                // Never guess which translation belongs to which screen region.
                onUpdate(completed)
                for region in batch where completed[region.id] == nil { try await single(region) }
            }
        }
        var jobs: [(Direction,[ScreenshotTextRegion])] = []
        for direction in [Direction.toChinese, .toEnglish] {
            var seen = Set<String>()
            let pending = document.regions.filter { (forcedDirection ?? $0.direction) == direction && completed[$0.id] == nil && seen.insert($0.text).inserted }
            let batchCount = max(1,Int(ceil(Double(pending.count)/Double(batchLimit))))
            let batchSize = min(batchLimit,max(1,Int(ceil(Double(pending.count)/Double(batchCount)))))
            var current: [ScreenshotTextRegion] = [], count = 0
            for region in pending {
                if current.count == batchSize || (!current.isEmpty && count+region.text.count > 4000) { jobs.append((direction,current)); current = []; count = 0 }
                current.append(region); count += region.text.count+40
            }
            if !current.isEmpty { jobs.append((direction,current)) }
        }
        requestedNetwork = requestedNetwork || !jobs.isEmpty
        onCommit(completed)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                func submit() {
                    let job = jobs[next]; next += 1
                    group.addTask { @MainActor in try Task.checkCancellation(); try await batch(job.1,direction: job.0) }
                }
                for _ in 0..<min(concurrency,jobs.count) { submit() }
                while try await group.next() != nil { if next < jobs.count { submit() } }
            }
        } catch {
            onUpdate(completed) // Incomplete previews never become completed/copyable text.
            throw error
        }
        onUpdate(completed); onProgress(completed.count, document.regions.count, false)
    }
}

enum ScreenshotTranslationRules {
    static func needsTranslation(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^(?:[A-Za-z]|[A-Z]{2,6})$"#, options: .regularExpression) != nil { return false }
        if value.range(of: #"^[\d\s.,:/%+\-−×()…•]+(?:\s*(?:B|KB|MB|GB|TB|ms|px|kg|Hz|fps|°C))?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if value.range(of: #"^[A-Za-z]?(?:[_₀-₉\d]|\([^\p{Han}]*\)|[=+−×/√∑∂]).*$"#, options: .regularExpression) != nil && value.count < 28 && !value.contains(" ") { return false }
        return value.rangeOfCharacter(from: .letters) != nil
    }
}

enum ScreenshotLanguage: String, CaseIterable {
    case automatic = "自动", chinese = "中文", english = "English"
    var direction: Direction? { self == .automatic ? nil : self == .chinese ? .toChinese : .toEnglish }
}

enum ScreenshotPresentation: String, CaseIterable {
    case overlay = "原位置覆盖", window = "翻译窗口"
}
