// Sonuvi — GPL-3.0.
import SwiftUI
import AppKit
import Carbon

struct BrandIcon: View {
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let image = NSImage(named: "BrandIcon") { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: "character.bubble.fill").resizable().scaledToFit().padding(6) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .frame(width: MuseLayout.sidebarIcon, height: MuseLayout.sidebarIcon)
            .background(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .shadow(color: color.opacity(0.10), radius: 1, y: 1).accessibilityHidden(true)
    }
}

extension ShortcutSpec {
    var menuKey: String { String(label.suffix(1)).lowercased() }
    var menuModifiers: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        for (carbon, cocoa) in [(controlKey, NSEvent.ModifierFlags.control), (optionKey, .option), (shiftKey, .shift), (cmdKey, .command)] {
            if modifiers & UInt32(carbon) != 0 { value.insert(cocoa) }
        }
        return value
    }
}

/// One dot per day, oldest first. Glow is tied to actual activity.
struct ActivityMatrix: View {
    let rows: [UsageDay]
    var compact = false
    @Environment(\.colorScheme) private var scheme
    @State private var selected: Int?
    private var columns: Int { compact ? rows.count : 30 }
    private var lines: Int { max(1, Int(ceil(Double(rows.count) / Double(max(1, columns))))) }
    private var maximum: Int { max(1, rows.map { $0.translations + $0.readings }.max() ?? 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Canvas { context, size in
                let stepX = size.width / CGFloat(max(1, columns)), stepY = size.height / CGFloat(lines)
                for (index, row) in rows.enumerated() {
                    let count = row.translations + row.readings
                    let intensity = Double(count) / Double(maximum)
                    let radius = min(compact ? 2.5 : 3.6, stepX * 0.28)
                    let center = CGPoint(x: (CGFloat(index % max(1, columns)) + 0.5) * stepX, y: (CGFloat(index / max(1, columns)) + 0.5) * stepY)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    let tint = Color(red: 0.24, green: 0.78, blue: 0.59)
                    if count > 0 {
                        context.drawLayer { glow in
                            glow.addFilter(.blur(radius: compact ? 3 : 5))
                            glow.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(tint.opacity(0.25 + intensity * 0.4)))
                        }
                    }
                    context.fill(Path(ellipseIn: rect), with: .color(count > 0 ? tint.opacity(0.45 + intensity * 0.55) : Color.primary.opacity(scheme == .dark ? 0.12 : 0.09)))
                    if selected == index { context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.primary.opacity(0.5)), lineWidth: 1) }
                }
            }.frame(height: compact ? 15 : 66).contentShape(Rectangle())
                .overlay { GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let column = min(max(0, columns - 1), max(0, Int(point.x / max(1, geometry.size.width) * CGFloat(columns))))
                            let line = min(lines - 1, max(0, Int(point.y / max(1, geometry.size.height) * CGFloat(lines))))
                            let index = line * columns + column
                            selected = rows.indices.contains(index) ? index : nil
                        case .ended: selected = nil
                        }
                    }
                } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("最近 \(rows.count) 天活动，\(rows.filter { $0.translations + $0.readings > 0 }.count) 天有使用"))
            if !compact {
                HStack {
                    LText(selected.flatMap { rows.indices.contains($0) ? rows[$0] : nil }.map { "\($0.id) · 翻译 \($0.translations) 次 · 朗读 \($0.readings) 次" } ?? "最近 90 天 · 每一个光点，都是一天的积累")
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(minHeight: 28, alignment: .topLeading)
            }
        }
    }
}

struct MenuSummary: View {
    @ObservedObject var usage: UsageStore
    @ObservedObject var motion: MenuMotion
    private var activeDays: Int { usage.recent(7).filter { $0.translations + $0.readings > 0 }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                BrandIcon(size: 20)
                LText("Sonuvi").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                LText("连续 \(usage.streak) 天").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                LText("今天").foregroundStyle(.secondary)
                LText("\(usage.today.translations) 次翻译").monospacedDigit()
                LText("·").foregroundStyle(.tertiary)
                LText("\(usage.today.readings) 次朗读").monospacedDigit()
                Spacer(minLength: 0)
            }.font(.system(size: 11)).lineLimit(1)
            FlowingDots(progress: Double(activeDays) / 7, compact: true, animate: motion.active)
                .frame(height: 28).accessibilityHidden(true)
                .help(L10n.text("最近 7 天使用 \(activeDays) 天"))
        }.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 7)
            .frame(width: 296, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
