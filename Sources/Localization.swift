// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable {
    case system, chinese = "zh-Hans", english = "en"
    var label: String {
        switch self { case .system: return L10n.text("跟随系统"); case .chinese: return "简体中文"; case .english: return "English" }
    }
    func resolved(preferred: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .chinese: return "zh-Hans"
        case .english: return "en"
        case .system: return preferred.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
    }
}

final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    @Published var language: AppLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    var locale: Locale { Locale(identifier: language.resolved()) }
}

enum L10n {
    static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "English", withExtension: "json"),
              let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return entries
    }()
    private static let patterns: [(NSRegularExpression, String, Int)] = english.keys.filter { $0.contains("{0}") }.sorted { $0.count > $1.count }.compactMap { key in
        var pattern = ""; var index = 0; var remainder = key[...]
        while let range = remainder.range(of: "{\(index)}") {
            pattern += NSRegularExpression.escapedPattern(for: String(remainder[..<range.lowerBound])) + "(.*?)"
            remainder = remainder[range.upperBound...]; index += 1
        }
        pattern += NSRegularExpression.escapedPattern(for: String(remainder))
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators]) else { return nil }
        return (regex, english[key]!, index)
    }
    static func text(_ value: String) -> String { translate(value, language: AppLocalization.shared.language.resolved()) }
    static func translate(_ value: String, language: String) -> String {
        guard language == "en" else { return value }
        if let exact = english[value] { return exact }
        let range = NSRange(value.startIndex..., in: value)
        for (regex, template, count) in patterns {
            guard let match = regex.firstMatch(in: value, range: range) else { continue }
            var result = template
            for i in 0..<count {
                if let capture = Range(match.range(at: i + 1), in: value) { result = result.replacingOccurrences(of: "{\(i)}", with: translate(String(value[capture]), language: language)) }
            }
            return result
        }
        return value
    }
}

// Localize interface copy at the presentation boundary. Source text, dictionary
// definitions and translation results keep their original Text views untouched.
struct LText: View {
    let value: String
    @ObservedObject private var localization = AppLocalization.shared
    init(_ value: String) { self.value = value }
    var body: some View { Text(verbatim: L10n.text(value)) }
}

struct LocalizedRoot<Content: View>: View {
    let content: Content
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View { content.environment(\.locale, localization.locale) }
}

struct MenuBarWelcomeTip: View {
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BrandIcon(size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    LText("让英文，自然读给你听").font(.system(size: 14, weight: .semibold))
                    LText("Sonuvi 已在菜单栏就位").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            LText("选中英文，即可用自然的声音朗读。模型在本机运行，离线也能听。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                LText("点击上方图标，打开菜单与设置")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.text("知道了"), action: close).controlSize(.small).fixedSize()
            }
        }.padding(18).frame(width: 320).fixedSize(horizontal: false, vertical: true)
    }
}
