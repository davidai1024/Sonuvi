// Sonuvi — GPL-3.0.
// Compact query layout informed by Easydict; independently implemented in SwiftUI.
import AppKit
import SwiftUI

struct TranslateView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var focusRequest = 0
    @State private var sourceHeight: CGFloat = 24
    @State private var sourceBottom: CGFloat = .greatestFiniteMagnitude
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hasSource: Bool { !model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var translated: String { model.word?.translation ?? model.result }
    private var sourceLanguage: String { hasSource ? (model.direction == .toChinese ? "英语" : "中文") : "自动检测" }
    private var targetLanguage: String { hasSource ? (model.direction == .toChinese ? "中文" : "英语") : "自动选择" }
    private var cardColor: Color { scheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.04) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 8) {
                        sourceCard.id("translation-source")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: SourceCardBottom.self,
                                    value: geometry.frame(in: .named("translation-viewport")).maxY)
                            })
                        languageBar
                        resultCard
                    }.padding(.horizontal, 12).padding(.bottom, 8)
                        .background(TranslationScrollAppearance())
                        .background(GeometryReader { geometry in Color.clear.preference(key: TranslationHeight.self, value: geometry.size.height) })
                }
                .coordinateSpace(name: "translation-viewport")
                .onPreferenceChange(SourceCardBottom.self) { sourceBottom = $0 }
                .overlay(alignment: .top) {
                    if hasSource && SourceRecall.isVisible(sourceBottom: sourceBottom) {
                        sourceRecall {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                reader.scrollTo("translation-source", anchor: .top)
                            }
                            focusRequest += 1
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .onChange(of: model.source) { _ in
                    // A fresh query should not inherit a hidden source from the last result.
                    if SourceRecall.isVisible(sourceBottom: sourceBottom) {
                        reader.scrollTo("translation-source", anchor: .top)
                    }
                }
            }
            HStack(spacing: 6) {
                if model.readingActive && model.readingPresentation == .inline {
                    SpeechDots(meter: model.playback.meter)
                    LText(model.readingStatus ?? "正在朗读").lineLimit(1)
                    Button { model.stopSpeaking() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(MuseHoverStyle(radius: 5)).help(L10n.text("停止朗读")).accessibilityLabel(L10n.text("停止底部朗读"))
                } else {
                    LText(model.toast.isEmpty ? "划词翻译 " + model.translateShortcut.label : model.toast)
                }
                Spacer(minLength: 8)
                LText("⌘↩ 翻译")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).frame(height: 26)
        }.frame(minWidth: 360, minHeight: 320)

            .onPreferenceChange(TranslationHeight.self) { height in
                guard height > 0 else { return }
                DispatchQueue.main.async { model.onTranslationHeightChanged?(height + 64) }
            }
    }

    private func sourceRecall(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LText("原文").font(.system(size: 11, weight: .medium))
                Text(SourceRecall.summary(model.source)).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 10).frame(height: SourceRecall.height)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(MuseHoverStyle(radius: 8))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .help(L10n.text("返回原文"))
        .accessibilityLabel(L10n.text("返回原文"))
        .accessibilityIdentifier("translation.source-return")
    }

    var toolbar: some View {
        HStack(spacing: 2) {
            tool(model.keepOnTop ? "pin.fill" : "pin", model.keepOnTop ? "取消置顶" : "窗口置顶") {
                model.keepOnTop.toggle()
                UserDefaults.standard.set(model.keepOnTop, forKey: "keepOnTop")
            }.foregroundStyle(model.keepOnTop ? Color.accentColor : .secondary)
            Spacer(minLength: 0)
            AppUpdateNotice(updates: model.updates)
            if let id = model.sourceApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                    .help(L10n.text("选词来源：" + url.deletingPathExtension().lastPathComponent)).padding(.trailing, 4)
            }
            Menu {
                Button(L10n.text("粘贴并翻译")) {
                    if let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.setSource(text); model.translate()
                    }
                }
                Button(L10n.text("截图翻译 " + model.ocrShortcut.label)) { model.startOCR?() }
                Divider()
                Picker(L10n.text("展示方式"), selection: $model.inputKind) {
                    ForEach(InputKind.allCases, id: \.self) { LText($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "textformat").font(.system(size: 14)).frame(width: 28, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L10n.text("输入与展示方式")).accessibilityLabel(L10n.text("输入与展示方式"))
            tool("gearshape", "设置") { model.openSettings?() }
            tool("xmark", "关闭翻译窗口") { model.hideWindow?() }.keyboardShortcut("w", modifiers: .command)
        }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if !hasSource {
                    LText(model.ocrRecognizing ? "正在识别选区文字…" : "选中文字，或在这里输入…").font(.system(size: 13, weight: .regular)).foregroundStyle(.tertiary).padding(.top, 1).allowsHitTesting(false)
                }
                TranslationEditor(text: $model.source, height: $sourceHeight, focusRequest: focusRequest,
                    onSelection: { model.onLocalSelection?($0, $1, $2) })
                    .frame(height: sourceHeight)
                    .accessibilityLabel(L10n.text("原文"))
            }.font(.system(size: 15)).lineSpacing(4)
            HStack(spacing: 0) {
                tool(model.speaking ? "stop.fill" : "speaker.wave.2", model.speaking ? "停止朗读" : (model.direction == .toChinese ? "朗读原文" : "本地朗读支持英文")) { model.speak(model.source) }
                    .disabled(!model.speaking && (!hasSource || model.direction != .toChinese))
                tool("doc.on.doc", "复制原文") { model.copy(model.source) }.disabled(!hasSource)
                if hasSource {
                    HStack(spacing: 3) {
                        LText("识别为").foregroundStyle(.secondary)
                        LText(sourceLanguage).foregroundStyle(.blue)
                    }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.primary.opacity(0.045), in: Capsule()).padding(.leading, 6)
                }
                Spacer(minLength: 4)
                Button(L10n.text(model.busy || model.ocrRecognizing ? "取消" : "翻译")) { model.busy || model.ocrRecognizing ? model.cancel() : model.translate() }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).frame(height: 28)
                    .buttonStyle(MuseHoverStyle(radius: 6)).foregroundStyle(.blue)
                    .disabled(!hasSource && !model.busy && !model.ocrRecognizing).keyboardShortcut(.return, modifiers: .command)
            }.padding(.horizontal, -4)
        }.padding(10).background(cardColor, in: RoundedRectangle(cornerRadius: 9))
    }

    private var languageBar: some View {
        HStack(spacing: 0) {
            LText(hasSource ? "自动检测 · " + sourceLanguage : "自动检测")
                .frame(maxWidth: .infinity).help(L10n.text("自动识别中文或英文"))
            Button {
                let text = translated
                model.setSource(text); model.translate()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(MuseHoverStyle(radius: 6))
                .help(L10n.text("用译文反向翻译")).accessibilityLabel(L10n.text("用译文反向翻译"))
                .disabled(model.busy || translated.isEmpty)
            LText(targetLanguage).frame(maxWidth: .infinity).help(L10n.text("中文译为英文，英文译为中文"))
        }.font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary).frame(height: 28)
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 10, weight: .regular))
                LText(model.effectiveKind == .word && hasSource ? "DeepSeek 词典" : "DeepSeek 翻译")
                    .font(.system(size: 11, weight: .regular))
                Spacer(minLength: 8)
                if model.busy || model.ocrRecognizing { ProgressView().controlSize(.mini) }
            }.foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 28)
            VStack(alignment: .leading, spacing: 10) {
                if !model.statusText.isEmpty {
                    LText(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("translation.progress")
                }
                if !model.error.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.text(model.error), systemImage: "exclamationmark.circle").textSelection(.enabled)
                        HStack(spacing: 12) {
                            if let tab = model.recoverySettingsTab {
                                Button(L10n.text(tab == "权限" ? "检查权限" : "打开模型设置")) {
                                    model.settingsTab = tab; model.openSettings?()
                                }
                            } else { Button(L10n.text("重试")) { model.translate() }.disabled(!hasSource) }
                            Button(L10n.text("截图翻译")) { model.startOCR?() }
                        }.buttonStyle(.borderless)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let word = model.word {
                    dictionary(word)
                } else if !model.result.isEmpty {
                    Text(model.result).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.error.isEmpty && model.ocrRecognizing {
                    LText("正在本机识别文字，随后自动翻译…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(minHeight: 44, alignment: .topLeading)
                } else if model.error.isEmpty && model.busy {
                    LText(model.statusText.isEmpty ? "正在翻译…" : "译文将逐段显示")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(minHeight: 44, alignment: .topLeading)
                } else if model.error.isEmpty {
                    LText(hasSource ? "点击翻译查看结果" : "译文将显示在这里")
                        .font(.system(size: 11, weight: .regular)).foregroundStyle(.tertiary)
                        .frame(minHeight: 44, alignment: .topLeading)
                }
                if !translated.isEmpty {
                    HStack(spacing: 0) {
                        tool(model.speaking ? "stop.fill" : "speaker.wave.2", model.speaking ? "停止朗读" : (model.direction == .toEnglish ? "朗读译文" : "本地朗读支持英文")) { model.speak(translated) }
                            .disabled(!model.speaking && (model.busy || model.direction != .toEnglish))
                        tool("doc.on.doc", "复制译文") { model.copy(translated) }.disabled(model.busy)
                        Spacer()
                        if model.word != nil { LText("AI 释义").font(.system(size: 10)).foregroundStyle(.tertiary) }
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
        }.buttonStyle(MuseHoverStyle(radius: 6)).help(L10n.text(title)).accessibilityLabel(L10n.text(title))
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
    var onSelection: (NSPoint, Int, Bool) -> Void
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
        TranslationScrollStyle.apply(to: scroll)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        let editor = TranslationTextView(frame: .zero)
        editor.onSelectionEnded = { [weak coordinator = context.coordinator] point, clicks, shift in
            coordinator?.owner.onSelection(point, clicks, shift)
        }
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
        editor.setAccessibilityLabel(L10n.text("原文")); editor.delegate = context.coordinator
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
            // Restore the beginning of long source text as well as the outer card.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
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
    var onSelectionEnded: ((NSPoint, Int, Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // NSTextView can consume mouse-up inside its own tracking loop.
        // Report after that loop commits the selection as well as monitoring
        // ordinary dispatched events; the gesture state deduplicates them.
        onSelectionEnded?(NSEvent.mouseLocation, event.clickCount, event.modifierFlags.contains(.shift))
    }
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
    override func layout() { super.layout(); TranslationScrollStyle.apply(to: self); scheduleMeasurement() }
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


private struct SourceCardBottom: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

enum SourceRecall {
    static let height: CGFloat = 34
    static func isVisible(sourceBottom: CGFloat) -> Bool { sourceBottom <= height }
    static func summary(_ source: String) -> String {
        // Limit work for long selections; never render the full source a second time.
        String(source.prefix(100)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Keep AppKit's native tracking, hit area and overlay fade; only draw a slim
/// thumb. Never paint the legacy knob slot, including when Always Show is set.
final class TranslationScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnob() {
        guard isEnabled, knobProportion < 1 else { return }
        let native = rect(for: .knob)
        guard native.width > 0 && native.height > 0 else { return }
        let thumb = NSRect(x: native.midX - 2, y: native.minY, width: 4, height: native.height)
        NSColor.labelColor.withAlphaComponent(0.34).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
    }
}

enum TranslationScrollStyle {
    static func apply(to scroll: NSScrollView) {
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        if scroll.drawsBackground { scroll.drawsBackground = false }
        if scroll.contentView.drawsBackground { scroll.contentView.drawsBackground = false }
        if !(scroll.verticalScroller is TranslationScroller) {
            let thumb = TranslationScroller()
            thumb.controlSize = .small
            scroll.verticalScroller = thumb
        }
    }
}

/// This probe lives inside the outer document, so the closest enclosing scroll
/// view is the translation viewport, never the nested source editor or Settings.
private struct TranslationScrollAppearance: NSViewRepresentable {
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); configure() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        func configure() {
            if let scroll = enclosingScrollView { TranslationScrollStyle.apply(to: scroll) }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.configure()
        DispatchQueue.main.async { [weak view] in view?.configure() }
    }
}
