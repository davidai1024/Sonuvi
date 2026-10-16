// Sonuvi — GPL-3.0. Shared macOS layout measurements (points).
import SwiftUI
import AppKit

enum MuseLayout {
    static let windowInset: CGFloat = 8
    static let sidebarWidth: CGFloat = 216
    static let sidebarRow: CGFloat = 34
    static let sidebarIcon: CGFloat = 20
    static let contentInset: CGFloat = 28
    static let sectionGap: CGFloat = 24
    static let cardInset: CGFloat = 16
    static let rowHeight: CGFloat = 56
    static let pageTitle = Font.system(size: 32, weight: .bold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let detail = Font.system(size: 12)
    static let caption = Font.system(size: 11)
}

struct SettingsSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(scheme == .dark ? Color.black.opacity(0.13) : Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    let symbol: String
    var stacked = false
    @ViewBuilder let control: () -> Control
    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(MuseLayout.sectionTitle).foregroundStyle(.primary)
                if !detail.isEmpty { Text(detail).font(MuseLayout.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 12) { label; control().padding(.leading, 34) }
            } else {
                HStack(spacing: 20) { label; control().fixedSize(horizontal: true, vertical: false) }
            }
        }.frame(maxWidth: .infinity, minHeight: MuseLayout.rowHeight - 16, alignment: .leading)
            .padding(.horizontal, MuseLayout.cardInset).padding(.vertical, 8)
    }
}

struct AppearanceSegments: View {
    @Binding var value: AppearanceMode
    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Button { value = mode } label: {
                    Text(mode == .system ? "系统" : mode.rawValue).font(.system(size: 12, weight: .semibold)).frame(width: 52, height: 30)
                        .background(value == mode ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(value == mode ? Color.primary.opacity(0.13) : .clear))
                }.buttonStyle(MuseHoverStyle(radius: 9)).accessibilityLabel(mode.rawValue).accessibilityAddTraits(value == mode ? [.isSelected] : [])
            }
        }.padding(3).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }
}
