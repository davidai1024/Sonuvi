// Sonuvi — GPL-3.0.
// Compact query layout informed by Easydict; independently implemented in SwiftUI.
import AppKit
import SwiftUI

struct TranslateView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var focusRequest = 0
    @State private var sourceHeight: CGFloat = 24
    private var hasSource: Bool { !model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var translated: String { model.word?.translation ?? model.result }
    private var sourceLanguage: String { hasSource ? (model.direction == .toChinese ? "英语" : "中文") : "自动检测" }
    private var targetLanguage: String { hasSource ? (model.direction == .toChinese ? "中文" : "英语") : "自动选择" }
    private var cardColor: Color { scheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.04) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(spacing: 8) {
                    sourceCard
                    languageBar
                    resultCard
                }.padding(.horizontal, 12).padding(.bottom, 8)
                    .background(GeometryReader { geometry in Color.clear.preference(key: TranslationHeight.self, value: geometry.size.height) })
            }
            HStack(spacing: 6) {
                if model.readingActive && model.readingPresentation == .inline {
                    SpeechDots(meter: model.playback.meter)
                    Text(model.readingStatus ?? "正在朗读").lineLimit(1)
                    Button { model.stopSpeaking() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(MuseHoverStyle(radius: 5)).help("停止朗读").accessibilityLabel("停止底部朗读")
                } else {
                    Text(model.toast.isEmpty ? "划词翻译 " + model.translateShortcut.label : model.toast)
                }
                Spacer(minLength: 8)
                Text("⌘↩ 翻译")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).frame(height: 26)
        }.frame(minWidth: 360, minHeight: 320)

            .onPreferenceChange(TranslationHeight.self) { height in
                guard height > 0 else { return }
                DispatchQueue.main.async { model.onTranslationHeightChanged?(height + 64) }
            }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            tool(model.keepOnTop ? "pin.fill" : "pin", model.keepOnTop ? "取消置顶" : "窗口置顶") {
                model.keepOnTop.toggle()
                UserDefaults.standard.set(model.keepOnTop, forKey: "keepOnTop")
            }.foregroundStyle(model.keepOnTop ? Color.accentColor : .secondary)
            Spacer()
            if let id = model.sourceApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                    .help("选词来源：" + url.deletingPathExtension().lastPathComponent).padding(.trailing, 4)
            }
            Menu {
                Button("粘贴并翻译") {
                    if let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.setSource(text); model.translate()
                    }
                }
                Button("截图翻译 " + model.ocrShortcut.label) { model.startOCR?() }
                Divider()
                Picker("展示方式", selection: $model.inputKind) {
                    ForEach(InputKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "textformat").font(.system(size: 14)).frame(width: 28, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("输入与展示方式").accessibilityLabel("输入与展示方式")
            tool("gearshape", "设置") { model.openSettings?() }
            tool("xmark", "关闭翻译窗口") { model.hideWindow?() }.keyboardShortcut("w", modifiers: .command)
        }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if !hasSource {
                    Text("选中文字，或在这里输入…").font(.system(size: 13, weight: .regular)).foregroundStyle(.tertiary).padding(.top, 1).allowsHitTesting(false)
                }
                TranslationEditor(text: $model.source, height: $sourceHeight, focusRequest: focusRequest)
                    .frame(height: sourceHeight)
                    .accessibilityLabel("原文")
            }.font(.system(size: 15)).lineSpacing(4)
            HStack(spacing: 0) {
                tool(model.speaking ? "stop.fill" : "speaker.wave.2", model.speaking ? "停止朗读" : (model.direction == .toChinese ? "朗读原文" : "本地朗读支持英文")) { model.speak(model.source) }
                    .disabled(!model.speaking && (!hasSource || model.direction != .toChinese))
                tool("doc.on.doc", "复制原文") { model.copy(model.source) }.disabled(!hasSource)
                if hasSource {
                    HStack(spacing: 3) {
                        Text("识别为").foregroundStyle(.secondary)
                        Text(sourceLanguage).foregroundStyle(.blue)
                    }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.primary.opacity(0.045), in: Capsule()).padding(.leading, 6)
                }
                Spacer(minLength: 4)
                Button(model.busy ? "取消" : "翻译") { model.busy ? model.cancel() : model.translate() }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).frame(height: 28)
                    .buttonStyle(MuseHoverStyle(radius: 6)).foregroundStyle(.blue)
                    .disabled(!hasSource && !model.busy).keyboardShortcut(.return, modifiers: .command)
            }.padding(.horizontal, -4)
        }.padding(10).background(cardColor, in: RoundedRectangle(cornerRadius: 9))
    }

    private var languageBar: some View {
        HStack(spacing: 0) {
            Text(hasSource ? "自动检测 · " + sourceLanguage : "自动检测")
                .frame(maxWidth: .infinity).help("自动识别中文或英文")
            Button {
                let text = translated
                model.setSource(text); model.translate()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(MuseHoverStyle(radius: 6))
                .help("用译文反向翻译").accessibilityLabel("用译文反向翻译")
                .disabled(model.busy || translated.isEmpty)
            Text(targetLanguage).frame(maxWidth: .infinity).help("中文译为英文，英文译为中文")
        }.font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary).frame(height: 28)
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 10, weight: .regular))
                Text(model.effectiveKind == .word && hasSource ? "DeepSeek 词典" : "DeepSeek 翻译")
                    .font(.system(size: 11, weight: .regular))
                Spacer(minLength: 8)
                if model.busy { ProgressView().controlSize(.mini) }
            }.foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 28)
            VStack(alignment: .leading, spacing: 10) {
                if !model.error.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.error, systemImage: "exclamationmark.circle").textSelection(.enabled)
                        HStack(spacing: 12) {
                            if let tab = model.recoverySettingsTab {
                                Button(tab == "通用" ? "检查权限" : "打开模型设置") {
                                    model.settingsTab = tab; model.openSettings?()
                                }
                            } else { Button("重试") { model.translate() }.disabled(!hasSource) }
                            Button("截图翻译") { model.startOCR?() }
                        }.buttonStyle(.borderless)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let word = model.word {
                    dictionary(word)
                } else if !model.result.isEmpty {
                    Text(model.result).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.busy {
                    Text(model.statusText.isEmpty ? "正在翻译…" : model.statusText)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(minHeight: 44, alignment: .topLeading)
                } else {
                    Text(hasSource ? "点击翻译查看结果" : "译文将显示在这里")
                        .font(.system(size: 11, weight: .regular)).foregroundStyle(.tertiary)
                        .frame(minHeight: 44, alignment: .topLeading)
                }
                if !translated.isEmpty {
                    HStack(spacing: 0) {
                        tool(model.speaking ? "stop.fill" : "speaker.wave.2", model.speaking ? "停止朗读" : (model.direction == .toEnglish ? "朗读译文" : "本地朗读支持英文")) { model.speak(translated) }
                            .disabled(!model.speaking && (model.busy || model.direction != .toEnglish))
                        tool("doc.on.doc", "复制译文") { model.copy(translated) }.disabled(model.busy)
                        Spacer()
                        if model.word != nil { Text("AI 释义").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    }.padding(.horizontal, -4)
                }
            }.padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.background(cardColor, in: RoundedRectangle(cornerRadius: 9))
    }

    private func dictionary(_ word: WordResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(word.translation).font(.system(size: 17, weight: .medium)).textSelection(.enabled)
            if !word.phonetic.isEmpty {
                Text(word.phonetic).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(Array(word.definitions.enumerated()), id: \.offset) { _, definition in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(definition.pos).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(definition.meaning).font(.system(size: 13)).lineSpacing(3)
                }.textSelection(.enabled)
            }
            if !word.example.isEmpty {
                Divider().opacity(0.5)
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(word.example).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                        if !word.exampleTranslation.isEmpty {
                            Text(word.exampleTranslation).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    tool(model.speaking ? "stop.fill" : "speaker.wave.2", "朗读例句") { model.speak(word.example) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tool(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(MuseHoverStyle(radius: 6)).help(title).accessibilityLabel(title)
    }
}

private struct TranslationHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// A native text view keeps standard editing/IME behavior without an always-visible
// scrollbar or the extra insets added by SwiftUI's macOS TextEditor.
private struct TranslationEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusRequest: Int
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: TranslationEditor
        var lastFocus = 0
        init(_ owner: TranslationEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            owner.text = view.string
            (view.enclosingScrollView as? ContentSizedTextScrollView)?.measureContent()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ContentSizedTextScrollView()
        scroll.onHeightChanged = { [weak coordinator = context.coordinator] height in
            guard let coordinator, abs(coordinator.owner.height - height) > 0.5 else { return }
            coordinator.owner.height = height
        }
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        let editor = TranslationTextView(frame: .zero)
        editor.isEditable = true; editor.isSelectable = true
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15); editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        editor.setAccessibilityLabel("原文"); editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text { editor.string = text }
        (scroll as? ContentSizedTextScrollView)?.scheduleMeasurement()
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            scroll.window?.makeFirstResponder(editor)
        }
    }
}

enum TextEditingCommands {
    static func perform(_ event: NSEvent, in editor: NSTextView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift] else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command, .shift] {
            guard key == "z", editor.isEditable else { return false }
            editor.undoManager?.redo(); return true
        }
        switch key {
        case "c": editor.copy(nil)
        case "a": editor.selectAll(nil)
        case "v" where editor.isEditable: editor.pasteAsPlainText(nil)
        case "x" where editor.isEditable: editor.cut(nil)
        case "z" where editor.isEditable: editor.undoManager?.undo()
        default: return false
        }
        return true
    }
}

final class TranslationTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TextEditingCommands.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

// Measure the laid-out glyphs, including a trailing empty line. Recalculate on
// text and width changes, and publish after AppKit/SwiftUI finish their layout.
final class ContentSizedTextScrollView: NSScrollView {
    static let maximumHeight: CGFloat = 180
    var onHeightChanged: ((CGFloat) -> Void)?
    private var measurementScheduled = false
    override func layout() { super.layout(); scheduleMeasurement() }
    func scheduleMeasurement() {
        guard !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementScheduled = false; self.measureContent()
        }
    }
    func measureContent() {
        guard let editor = documentView as? NSTextView, let container = editor.textContainer,
              let manager = editor.layoutManager, contentSize.width > 1 else { return }
        let width = contentSize.width
        if abs(editor.frame.width - width) > 0.5 { editor.setFrameSize(NSSize(width: width, height: editor.frame.height)) }
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        let used = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        let natural = max(24, ceil(used + editor.textContainerInset.height * 2))
        let height = min(Self.maximumHeight, natural)
        let needsScroller = natural > Self.maximumHeight
        if hasVerticalScroller != needsScroller { hasVerticalScroller = needsScroller }
        let documentHeight = max(natural, contentSize.height)
        if abs(editor.frame.height - documentHeight) > 0.5 { editor.setFrameSize(NSSize(width: width, height: documentHeight)) }
        onHeightChanged?(height)
    }
}
