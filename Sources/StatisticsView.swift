// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI
import Charts

struct UsageChart: View {
    let rows: [UsageDay]
    @State private var selected: String?
    var selectedRow: UsageDay? { rows.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(rows) { row in
                BarMark(x: .value("日期", row.id), y: .value("次数", row.lookups), width: .ratio(0.6))
                    .foregroundStyle(by: .value("类型", "查词"))
                BarMark(x: .value("日期", row.id), y: .value("次数", row.sentences), width: .ratio(0.6))
                    .foregroundStyle(by: .value("类型", "句子"))
                if selected == row.id { RuleMark(x: .value("日期", row.id)).foregroundStyle(.secondary.opacity(0.25)) }
            }.chartForegroundStyleScale(["查词": Color.green.opacity(0.8), "句子": Color.blue.opacity(0.65)])
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in AxisGridLine().foregroundStyle(.primary.opacity(0.06)); AxisValueLabel() } }
                .chartXAxis { AxisMarks(values: rows.enumerated().filter { rows.count <= 7 || $0.offset % 5 == 0 }.map { $0.element.id }) { value in
                    AxisValueLabel { if let id = value.as(String.self) { Text(String(id.suffix(5)).replacingOccurrences(of: "-", with: "/")).font(.system(size: 10)) } }
                } }.chartLegend(position: .bottom, alignment: .leading, spacing: 10).frame(height: 170)
                .chartOverlay { proxy in GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let x = point.x - geo[proxy.plotAreaFrame].origin.x
                            selected = proxy.value(atX: x, as: String.self)
                        case .ended: selected = nil
                        }
                    }
                } }
            Text(selectedRow.map { "\($0.id) · 查词 \($0.lookups) 次 · 句子 \($0.sentences) 次 · 朗读 \($0.readings) 次" } ?? "将指针移到柱形上查看当天用量，空白日期表示没有使用。")
                .font(.caption).foregroundStyle(.secondary).frame(minHeight: 28, alignment: .leading).accessibilityLabel("每日用量明细")
        }
    }
}

extension SettingsView {
    var statistics: some View {
        Group {
            if model.previewMode { Text("以下为预览数据，不会写入真实统计。").font(.caption).foregroundStyle(.secondary) }
            if !usage.storageError.isEmpty { Text(usage.storageError).font(.caption).foregroundStyle(.secondary) }
            if usage.total.translations + usage.total.readings == 0 {
                section("从第一次使用开始") { Text("完成翻译或朗读后，这里会显示你的使用积累。").foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("语言，正在变得熟悉").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(usage.total.words.formatted()).font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                            Text("个词，已经读懂").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 7) {
                        Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.green)
                        Text("连续 \(usage.streak) 天").font(.system(size: 12, weight: .medium))
                        Text("最长 \(usage.bestStreak) 天").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("词数积累").foregroundStyle(.secondary)
                        Spacer()
                        Text("下一里程碑 \(UsageMilestone.next(after: usage.total.words).formatted()) 词").foregroundStyle(.secondary)
                    }.font(.system(size: 11))
                    FlowingDots(progress: Double(usage.total.words) / Double(UsageMilestone.next(after: usage.total.words)))
                        .frame(height: 52).accessibilityHidden(true)
                }

            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.green.opacity(0.10), .clear], startPoint: .topTrailing, endPoint: .bottomLeading), in: RoundedRectangle(cornerRadius: 20))
                .museGlass(20)
            section("累计使用") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 12)], alignment: .leading, spacing: 16) {
                    metric("翻译", value: usage.total.translations, unit: "次", icon: "character.bubble")
                    metric("单词与短语", value: usage.total.lookups, unit: "次", icon: "textformat.abc")
                    metric("句子翻译", value: usage.total.sentences, unit: "次", icon: "text.alignleft")
                    metric("处理词数", value: usage.total.words, unit: "词", icon: "text.word.spacing")
                    metric("完成朗读", value: usage.total.readings, unit: "次", icon: "waveform")
                    metric("朗读词数", value: usage.total.readWords, unit: "词", icon: "speaker.wave.2")
                    metric("使用应用", value: usage.total.apps.count, unit: "个", icon: "app.dashed")
                    metric("活跃天数", value: usage.activeDays, unit: "天", icon: "calendar")
                }
                Divider().opacity(0.4)
                HStack { timeMetric("累计听读", seconds: usage.total.listeningSeconds); Spacer(); timeMetric("主动使用", seconds: usage.total.activeSeconds) }
                Text("词数按系统分词统计；主动使用仅计算窗口在前台、最近 60 秒内有交互的时间。朗读量仅计播放完成的内容。").font(.caption).foregroundStyle(.secondary)
            }
            section("活跃日历") { ActivityMatrix(rows: usage.recent(90)) }
            section("每日积累") {
                HStack { Text("今天 \(usage.today.translations) 次翻译").foregroundStyle(.secondary); Spacer(); Picker("统计周期", selection: $period) { Text("7 天").tag(7); Text("30 天").tag(30) }.pickerStyle(.segmented).labelsHidden().frame(width: 130) }
                UsageChart(rows: usage.recent(period))
            }
            section("小小成就") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    achievement("迈出第一步", detail: "完成首次翻译", icon: "sparkle", current: usage.total.translations, goal: 1)
                    achievement("百词有获", detail: "处理 100 个词", icon: "book.closed", current: usage.total.words, goal: 100)
                    achievement("日日有进", detail: "连续使用 7 天", icon: "calendar.badge.checkmark", current: usage.bestStreak, goal: 7)
                    achievement("听见一小时", detail: "完成 60 分钟听读", icon: "headphones", current: Int(usage.total.listeningSeconds / 60), goal: 60)
                }
            }
            section("本机统计") {
                Toggle("记录使用统计", isOn: $usage.enabled).onChange(of: usage.enabled) { value in if !model.previewMode { UserDefaults.standard.set(value, forKey: "usageEnabled") } }
                Text("只保存每日计数、时长和来源应用标识，不保存选中文字、译文或音频。关闭后保留已有数据并停止新增；移除朗读模型不会影响统计。").font(.caption).foregroundStyle(.secondary)
                HStack { Text("复制 \(usage.total.copies) 次 · 缓存命中 \(usage.total.cached) 次").font(.caption).foregroundStyle(.secondary); Spacer(); Button("清空统计…") { resetUsage() }.disabled(model.previewMode || usage.days.isEmpty) }
            }
        }
    }
    func metric(_ title: String, value: Int, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) { Text(value.formatted()).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit(); Text(unit).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    func timeMetric(_ title: String, seconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(seconds >= 3600 ? String(format: "%.1f 小时", seconds / 3600) : String(format: "%.1f 分钟", seconds / 60)).font(.system(size: 17, weight: .medium)).monospacedDigit() }
    }
    func achievement(_ title: String, detail: String, icon: String, current: Int, goal: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: current >= goal ? "checkmark" : icon).font(.system(size: 14, weight: .medium)).frame(width: 34, height: 34).background(.primary.opacity(current >= goal ? 0.10 : 0.04), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary); Text(current >= goal ? "已达成" : "\(min(current, goal)) / \(goal)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(current >= goal ? Color.green.opacity(0.07) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14)).accessibilityElement(children: .combine)
    }
    func resetUsage() {
        let alert = NSAlert(); alert.messageText = "清空本机统计？"; alert.informativeText = "现有统计文件会移到废纸篓，之后从零累计。"; alert.addButton(withTitle: "清空统计"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { do { try usage.reset() } catch { message = "统计未清空，请稍后重试。" } }
    }
}
