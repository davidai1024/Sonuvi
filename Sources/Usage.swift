// Sonuvi — GPL-3.0. Local aggregates only, never translation content.
import Foundation
import NaturalLanguage
import AppKit

struct UsageDay: Codable, Identifiable {
    var id: String
    var translations = 0
    var lookups = 0
    var sentences = 0
    var words = 0
    var characters = 0
    var readings = 0
    var readWords = 0
    var listeningSeconds: Double = 0
    var activeSeconds: Double = 0
    var copies = 0
    var cached = 0
    var apps: [String: Int] = [:]
    mutating func merge(_ other: Self) {
        translations += other.translations; lookups += other.lookups; sentences += other.sentences
        words += other.words; characters += other.characters; readings += other.readings; readWords += other.readWords
        listeningSeconds += other.listeningSeconds; activeSeconds += other.activeSeconds; copies += other.copies; cached += other.cached
        for (key, value) in other.apps { apps[key, default: 0] += value }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var days: [UsageDay] = []
    @Published var enabled = UserDefaults.standard.object(forKey: "usageEnabled") as? Bool ?? true
    @Published var storageError = ""
    var preview = false
    private var lastActivity = Date.distantPast
    private var lastTick = Date()
    private var dirty = false
    static var file: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MuseTranslate/Usage.json") }
    private let fileURL: URL
    init(fileURL: URL? = nil) {
        let fileURL = fileURL ?? Self.file
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            do { days = try JSONDecoder().decode([UsageDay].self, from: data) }
            catch { storageError = "统计文件暂时无法读取，已保留原文件。" }
        }
    }
    static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { count += 1 }; return true
        }
        return count
    }
    var today: UsageDay { days.first { $0.id == Self.key(Date()) } ?? UsageDay(id: Self.key(Date())) }
    var total: UsageDay { days.reduce(into: UsageDay(id: "total")) { $0.merge($1) } }
    var activeDays: Int { days.filter { $0.translations + $0.readings > 0 }.count }
    var bestStreak: Int {
        var best = 0; var current = 0; var previous: Date?
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar.current
        for row in days.filter({ $0.translations + $0.readings > 0 }).sorted(by: { $0.id < $1.id }) {
            guard let date = formatter.date(from: row.id) else { continue }
            current = previous.map { Calendar.current.dateComponents([.day], from: $0, to: date).day == 1 } == true ? current + 1 : 1
            best = max(best, current); previous = date
        }; return best
    }
    var streak: Int {
        var n = 0; let calendar = Calendar.current
        let offset = today.translations + today.readings > 0 ? 0 : 1
        for i in offset..<10000 {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()), let day = days.first(where: { $0.id == Self.key(date) }), day.translations + day.readings > 0 else { break }; n += 1
        }
        return n
    }
    func recent(_ count: Int) -> [UsageDay] {
        (0..<count).reversed().compactMap { i in
            guard let date = Calendar.current.date(byAdding: .day, value: -i, to: Date()) else { return nil }
            let id = Self.key(date); return days.first { $0.id == id } ?? UsageDay(id: id)
        }
    }
    private func update(_ block: (inout UsageDay) -> Void) {
        guard enabled, !preview, storageError.isEmpty else { return }
        let id = Self.key(Date()); var row = today; block(&row)
        if let index = days.firstIndex(where: { $0.id == id }) { days[index] = row } else { days.append(row) }
        dirty = true
    }
    func touch() { lastActivity = Date() }
    func tick(windowActive: Bool) {
        let now = Date(); let elapsed = min(15, max(0, now.timeIntervalSince(lastTick))); lastTick = now
        if windowActive && now.timeIntervalSince(lastActivity) < 60 { update { $0.activeSeconds += elapsed } }
        persist()
    }
    func translation(text: String, kind: InputKind, app: String?, cached: Bool) {
        touch(); update { day in
            day.translations += 1; day.lookups += kind == .word ? 1 : 0; day.sentences += kind == .word ? 0 : 1
            day.words += Self.wordCount(text); day.characters += text.filter { !$0.isWhitespace }.count
            day.cached += cached ? 1 : 0
            if let app, !app.isEmpty, app != Bundle.main.bundleIdentifier { day.apps[app, default: 0] += 1 }
        }; persist()
    }
    func reading(words: Int, seconds: Double, app: String?) {
        touch(); update { day in day.readings += 1; day.readWords += words; day.listeningSeconds += max(0, seconds); if let app, !app.isEmpty, app != Bundle.main.bundleIdentifier { day.apps[app, default: 0] += 1 } }; persist()
    }
    func copied() { touch(); update { $0.copies += 1 }; persist() }
    func persist() {
        guard dirty, !preview, storageError.isEmpty else { return }
        do { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(days).write(to: fileURL, options: .atomic); dirty = false }
        catch { storageError = "统计暂未保存，请检查磁盘空间与文件权限。" }
    }
    func reset() throws {
        guard !preview else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil) }
        days = []; dirty = false; storageError = ""
    }
    func loadPreview() {
        preview = true; days = (0..<14).reversed().map { i in
            let id = Self.key(Calendar.current.date(byAdding: .day, value: -i, to: Date())!)
            var d = UsageDay(id: id); d.translations = [12, 8, 24, 16, 0, 21, 9][i % 7]; d.lookups = d.translations * 2 / 3; d.sentences = d.translations - d.lookups
            d.words = d.translations * 8; d.readings = d.translations / 3; d.readWords = d.readings * 22; d.listeningSeconds = Double(d.readings * 40); d.activeSeconds = Double(d.translations * 35); d.apps = ["com.apple.Safari": 8, "com.apple.TextEdit": 3]; return d
        }
    }
}
