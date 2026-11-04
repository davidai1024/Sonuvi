// Sonuvi — GPL-3.0. Bounded, process-local reuse; screenshot text is never written to disk.
import Foundation

@MainActor
final class ScreenshotTranslationCache {
    static let shared = ScreenshotTranslationCache()
    private struct Entry { let value: String; let date: TimeInterval; var used: Int }
    private var entries: [String: Entry] = [:]
    private var clock = 0
    let capacity: Int
    let lifetime: TimeInterval
    init(capacity: Int = 512, lifetime: TimeInterval = 900) { self.capacity = capacity; self.lifetime = lifetime }
    private func key(_ model: String, _ text: String, _ direction: Direction) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + ScreenshotTranslationWork.cacheKey(text, direction: direction)
    }
    func values(document: ScreenshotDocument, model: String, direction: Direction?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: String] {
        var result: [String: String] = [:]
        for region in document.regions {
            let target = direction ?? region.direction, k = key(model,region.text,target)
            guard var entry = entries[k] else { continue }
            if now-entry.date > lifetime { entries.removeValue(forKey: k); continue }
            clock += 1; entry.used = clock; entries[k] = entry
            result[ScreenshotTranslationWork.cacheKey(region.text,direction: target)] = entry.value
        }
        return result
    }
    func store(document: ScreenshotDocument, values: [Int:String], model: String, direction: Direction?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for region in document.regions {
            guard let value = values[region.id], value != region.text, !value.isEmpty else { continue }
            let k = key(model,region.text,direction ?? region.direction)
            if entries[k]?.value == value { continue }
            clock += 1; entries[k] = Entry(value: value,date: now,used: clock)
        }
        while entries.count > capacity, let oldest = entries.min(by: {$0.value.used < $1.value.used})?.key { entries.removeValue(forKey: oldest) }
    }
}
