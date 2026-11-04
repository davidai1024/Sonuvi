// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI
import Vision
import ScreenCaptureKit
import ImageIO
import ServiceManagement
import Carbon

enum AppearanceMode: String, CaseIterable { case system = "跟随系统", light = "浅色", dark = "深色" }

struct ShortcutSpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    static let translate = ShortcutSpec(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧T")
    static let read = ShortcutSpec(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧S")
    static let ocr = ShortcutSpec(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧R")
    static func load(_ key: String, fallback: Self) -> Self {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data) else { return fallback }; return value
    }
    func store(_ key: String) { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: key) } }
    static func from(_ event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .command, .option]).isEmpty else { return nil }
        // charactersIgnoringModifiers still includes Option-produced symbols.
        // Resolve the key without modifiers so e.g. Option-T records T, not †.
        guard let character = event.characters(byApplyingModifiers: [])?.uppercased(), character.count == 1,
              character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        var mods: UInt32 = 0; var label = ""
        for (flag, code, glyph) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { mods |= UInt32(code); label += glyph }
        }
        return Self(keyCode: UInt32(event.keyCode), modifiers: mods, label: label + character)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: ShortcutSpec
    var isSelected = false
    var onRecording: (Bool) -> Void = { _ in }
    var onSelect: () -> Void = {}
    var onPressed: ([String]) -> Void = { _ in }
    final class Field: NSControl {
        // Draw a single rounded surface. NSButtonCell's highlight and native
        // focus ring otherwise overlap the custom recording border on Tahoe.
        var title = "" { didSet { needsDisplay = true } }
        var isSelected = false { didSet { refreshAppearance() } }
        private var hovered = false
        private var tracking: NSTrackingArea?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            focusRingType = .none
            setAccessibilityElement(true); setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.controlBackgroundColor.setFill(); path.fill()
            if active { NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); path.fill() }
            let focused = window?.firstResponder === self
            (active || focused ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(hovered || isSelected ? 0.85 : 0.45)).setStroke()
            path.lineWidth = active ? 2 : 1; path.stroke()
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: active ? NSColor.controlAccentColor : NSColor.labelColor, .paragraphStyle: style]
            let height = (title as NSString).size(withAttributes: attrs).height
            (title as NSString).draw(in: NSRect(x: 8, y: (bounds.height - height) / 2, width: max(0, bounds.width - 16), height: height), withAttributes: attrs)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        var change: ((ShortcutSpec) -> Void)?
        var saved = ""
        var recording: ((Bool) -> Void)?
        var selected: (() -> Void)?
        var pressed: (([String]) -> Void)?
        private var pending: ShortcutSpec?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var active = false
        var activeRecording: Bool { active }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { beginRecording() }
        override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
        private func beginRecording() {
            guard !active, window?.makeFirstResponder(self) == true else { return }
            active = true; selected?(); recording?(true)
            title = saved; refreshAppearance()
            NSAccessibility.post(element: self, notification: .valueChanged)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown]) { [weak self] event in
                guard let self, self.active, event.window === self.window else { return event }
                if event.type == .leftMouseDown {
                    if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.finishRecording() }
                    return event
                }
                self.capture(event); return nil
            }
            if let window {
                resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.finishRecording() }
            }
        }
        private func finishRecording() {
            guard active else { return }; active = false
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
            pending = nil; title = saved; refreshAppearance(); pressed?([]); recording?(false)
        }
        private func capture(_ event: NSEvent) {
            let modifiers: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            var glyphs = modifiers.filter { event.modifierFlags.contains($0.0) }.map { $0.1 }
            if event.type == .flagsChanged {
                pressed?(glyphs)
                if pending == nil { title = glyphs.isEmpty ? saved : glyphs.joined() + " …" }
                return
            }
            if event.type == .keyUp {
                if let spec = pending, spec.keyCode == UInt32(event.keyCode) {
                    finishRecording(); change?(spec); window?.makeFirstResponder(nil)
                } else { pressed?(glyphs) }
                return
            }
            if event.keyCode == 53 { finishRecording(); window?.makeFirstResponder(nil); return }
            if let character = event.characters(byApplyingModifiers: [])?.uppercased(), character.count == 1 { glyphs.append(character) }
            pressed?(glyphs)
            if let spec = ShortcutSpec.from(event) {
                // Keep capture active until key-up so the large keycaps can show
                // the physical press and the new global binding cannot fire here.
                pending = spec; title = spec.label
            } else {
                pending = nil; title = L10n.text("需要修饰键")
            }
        }
        func refreshAppearance() {
            setAccessibilityValue(active ? L10n.text("正在录制快捷键") : saved)
            needsDisplay = true
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }
        override func keyDown(with event: NSEvent) {
            if active { capture(event) }
            else if event.keyCode == 49 || event.keyCode == 36 { beginRecording() }
            else { super.keyDown(with: event) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard active else { return super.performKeyEquivalent(with: event) }; capture(event); return true
        }
        override func resignFirstResponder() -> Bool { finishRecording(); return super.resignFirstResponder() }
        override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { finishRecording() }; super.viewWillMove(toWindow: newWindow) }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) }; if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
    }
    func makeNSView(context: Context) -> Field {
        let field = Field(); field.focusRingType = .none
        field.toolTip = L10n.text("点击录制快捷键；Esc 取消。录制成功后立即生效。")
        return field
    }
    func updateNSView(_ field: Field, context: Context) { field.toolTip = L10n.text("点击录制快捷键；Esc 取消。录制成功后立即生效。"); field.isSelected = isSelected; field.saved = value.label; if !field.activeRecording { field.title = value.label }; field.change = { value = $0 }; field.recording = onRecording; field.selected = onSelect; field.pressed = onPressed; field.refreshAppearance() }
}

// Shared by Settings and onboarding: selected combination at rest, only the
// physically held keys while recording (never merge with the old modifiers).
struct ShortcutKeyPreview: View {
    var value: ShortcutSpec
    var pressed: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static func glyphs(value: ShortcutSpec, pressed: [String]) -> [String] {
        pressed.isEmpty ? value.label.map(String.init) : pressed
    }
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.glyphs(value: value, pressed: pressed).enumerated()), id: \.offset) { _, glyph in
                let held = pressed.contains(glyph)
                Text(glyph).font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56, height: 60)
                    .background(LinearGradient(colors: [Color(nsColor: .controlBackgroundColor), Color.accentColor.opacity(held ? 0.30 : 0.15)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
                    .padding(4).background(Color.accentColor.opacity(held ? 0.95 : 0.75), in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: Color.accentColor.opacity(held ? 0.24 : 0.10), radius: held ? 2 : 4, y: held ? 0 : 3)
                    .offset(y: held ? 2 : 0)
            }
        }.frame(maxWidth: .infinity).frame(height: 78)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pressed)
            .accessibilityElement(children: .ignore).accessibilityLabel(value.label)
    }
}

enum WindowGeometry {
    static func origin(near point: NSPoint, size: NSSize, visible frame: NSRect) -> NSPoint {
        NSPoint(x: max(frame.minX + 8, min(point.x + 14, frame.maxX - size.width - 8)),
                y: max(frame.minY + 8, min(point.y - size.height - 12, frame.maxY - size.height - 8)))
    }
}

enum OCRService {
    enum Input { case image(CGImage), file(URL) }
    static func recognize(_ input: Input) async throws -> String { try await recognizeDocument(input).text }
    static func recognizeDocument(_ input: Input, cpuOnly: Bool = false, timing: (@Sendable ([String:Double]) -> Void)? = nil) async throws -> ScreenshotDocument {
        let cancellation = ScreenshotOCRCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            let image: CGImage?
            switch input {
            case .image(let value): image = value
            case .file(let url): image = CGImageSourceCreateWithURL(url as CFURL,nil).flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) }
            }
            guard let image else { throw TranslateError.message("截图图像不可用。") }
            let prepared = ProcessInfo.processInfo.systemUptime
            let request = try ScreenshotVisionEngine.perform(image:image,cpuOnly:cpuOnly,cancellation:cancellation)
            let recognized = ProcessInfo.processInfo.systemUptime
            try Task.checkCancellation()
            let imageSize = CGSize(width: image.width,height:image.height)
            var protectedBounds: [CGRect] = []
            var prefixPixels: ScreenshotLayoutObstacles?
            let lines = (request.results ?? []).compactMap { observation -> ScreenshotTextLine? in
                guard let candidate = observation.topCandidates(1).first,
                      !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ScreenshotTextLine(text: candidate.string, bounds: observation.boundingBox, confidence: candidate.confidence)
            }
            // Vision can place several table cells in one observation. Recover
            // large word gaps before paragraph grouping; columns are separate
            // translation slots, not a sentence to reflow across the whole row.
            let separated = (request.results ?? []).flatMap { observation -> [ScreenshotTextLine] in
                guard let candidate = observation.topCandidates(1).first else { return [] }
                let raw = candidate.string
                var string = raw, sourceOffset = 0
                guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                var textBounds = observation.boundingBox
                func candidateBox(_ range: Range<String.Index>) -> CGRect? {
                    let lower = raw.index(raw.startIndex, offsetBy: sourceOffset + string.distance(from: string.startIndex, to: range.lowerBound))
                    let upper = raw.index(raw.startIndex, offsetBy: sourceOffset + string.distance(from: string.startIndex, to: range.upperBound))
                    return (try? candidate.boundingBox(for: lower..<upper))?.boundingBox
                }
                // Preserve detached icon/shortcut pixels on either side of a UI
                // label. They do not belong to the label's text or font metrics.
                for trailing in [false,true] {
                    guard string.count > 2 else { continue }
                    var cut: String.Index?
                    if trailing {
                        if let space = string.lastIndex(where: \.isWhitespace) { cut = string.index(after: space) }
                        if let last = string.last, last.isASCII, last.isLetter,
                           string.dropLast().unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
                            cut = string.index(before: string.endIndex)
                        }
                    } else {
                        cut = string.firstIndex(where: \.isWhitespace)
                        if let first = string.first, ScreenshotTextFilter.iconLike.contains(first) || !first.isLetter && !first.isNumber {
                            if cut == nil || string.distance(from:string.startIndex,to:cut!) > 3 { cut = string.index(after:string.startIndex) }
                        }
                        if let han = string.firstIndex(where: { $0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }),
                           string.distance(from:string.startIndex,to:han) <= 3, han > string.startIndex { cut = han }
                        if string.count > 2 {
                            let pair = String(string.prefix(2))
                            if pair.allSatisfy(\.isNumber) && Set(pair).count == 1 { cut = string.index(string.startIndex,offsetBy:2) }
                        }
                    }
                    for length in 1...min(6,string.count-2) {
                        let body = trailing ? String(string.dropLast(length)) : String(string.dropFirst(length))
                        if ScreenshotTextFilter.isUILabel(body.trimmingCharacters(in:.whitespacesAndNewlines)) {
                            cut = trailing ? string.index(string.endIndex,offsetBy:-length) : string.index(string.startIndex,offsetBy:length)
                            break
                        }
                    }
                    guard let cut, cut > string.startIndex, cut < string.endIndex else { continue }
                    let tokenRange = trailing ? cut..<string.endIndex : string.startIndex..<cut
                    let bodyRange = trailing ? string.startIndex..<cut : cut..<string.endIndex
                    let token = String(string[tokenRange]).trimmingCharacters(in:.whitespacesAndNewlines)
                    let body = String(string[bodyRange]).trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !token.isEmpty, token.count <= 6, body.count >= 2,
                          let first = candidateBox(tokenRange), let rest = candidateBox(bodyRange) else { continue }
                    let oldIcon = token.count == 1 && token.first.map(ScreenshotTextFilter.iconLike.contains) == true
                    let enclosed = token.unicodeScalars.allSatisfy { (0x2460...0x24FF).contains($0.value) || (0x2190...0x21FF).contains($0.value) }
                    let fileTile = !trailing && token.count == 1 && "PWX".contains(token)
                    // Most ordinary words never need an image scan.
                    let nominalIcon = CGRect(x:0,y:0,width:0.02,height:0.03), nominalLabel = CGRect(x:0.04,y:0,width:0.2,height:0.03)
                    let uiAffix = ScreenshotTextFilter.detachedAdornment(token,body:body,icon:nominalIcon,label:nominalLabel,imageSize:CGSize(width:1000,height:1000))
                    guard oldIcon || enclosed || fileTile || uiAffix else { continue }
                    var icon = first, label = rest
                    do {
                        if prefixPixels == nil { prefixPixels = ScreenshotLayoutObstacles(image:image,size:imageSize) }
                        if let split = trailing ? prefixPixels?.trailingIcon(in:textBounds) : prefixPixels?.leadingIcon(in:textBounds) { icon = split.icon; label = split.label }
                    }
                    var coloredTile = false
                    if fileTile, let color = ScreenshotRegionColors.sample(image:image,rect:ScreenshotLayout.rect(icon,in:imageSize).insetBy(dx:-2,dy:-2),size:imageSize).background.usingColorSpace(.sRGB) {
                        coloredTile = max(color.redComponent,color.greenComponent,color.blueComponent)-min(color.redComponent,color.greenComponent,color.blueComponent) > 0.35
                    }
                    guard ScreenshotTextFilter.detachedAdornment(token,body:body,icon:icon,label:label,imageSize:imageSize,coloredTile:coloredTile)
                          || ScreenshotTextFilter.iconPrefix(token,bounds:icon,label:label,imageSize:imageSize,coloredTile:coloredTile) else { continue }
                    protectedBounds.append(icon)
                    let trimmedStart = string[bodyRange].firstIndex(where: { !$0.isWhitespace })!
                    let trimmedEnd = string[bodyRange].lastIndex(where: { !$0.isWhitespace }).map { string.index(after:$0) }!
                    sourceOffset += string.distance(from:string.startIndex,to:trimmedStart)
                    string = String(string[trimmedStart..<trimmedEnd]); textBounds = label
                }
                var words: [(Range<String.Index>, CGRect)] = []
                string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byWords) { _, range, _, _ in
                    if let box = candidateBox(range) { words.append((range, box)) }
                }
                guard words.count > 1 else { return [ScreenshotTextLine(text: string, bounds: textBounds, confidence: candidate.confidence)] }
                var cuts: [String.Index] = [string.startIndex]
                for index in 1..<words.count {
                    let previous = String(string[words[index-1].0]), next = String(string[words[index].0])
                    let uiLanguageBoundary = TextRules.direction(previous) != TextRules.direction(next) && (ScreenshotTextFilter.isUILabel(previous) || ScreenshotTextFilter.isUILabel(next))
                    let prefix = String(string[..<words[index].0.lowerBound]).trimmingCharacters(in:.whitespacesAndNewlines)
                    let suffix = String(string[words[index].0.lowerBound...]).trimmingCharacters(in:.whitespacesAndNewlines)
                    let cellBoundary = ScreenshotTextFilter.isUILabel(prefix) && ScreenshotTextFilter.isUILabel(suffix)
                    if cellBoundary || uiLanguageBoundary || (words[index].1.minX - words[index-1].1.maxX) * imageSize.width > max(textBounds.height * imageSize.height * 0.85, 4) {
                        cuts.append(words[index].0.lowerBound)
                    }
                }
                let noise = Set(["C","Y","V","v","d","G","Q","<",">"])
                for (index,word) in words.enumerated() where noise.contains(String(string[word.0])) {
                    let prefix = String(string[..<word.0.lowerBound]).trimmingCharacters(in:.whitespacesAndNewlines)
                    let suffix = String(string[word.0.upperBound...]).trimmingCharacters(in:.whitespacesAndNewlines)
                    let neighborUI = ScreenshotTextFilter.isUILabel(prefix) || ScreenshotTextFilter.isUILabel(suffix)
                        || index > 0 && ScreenshotTextFilter.isUILabel(String(string[words[index-1].0]))
                        || index+1 < words.count && ScreenshotTextFilter.isUILabel(String(string[words[index+1].0]))
                    if neighborUI { cuts.append(word.0.lowerBound);if index+1 < words.count { cuts.append(words[index+1].0.lowerBound) } }
                }
                cuts = Array(Set(cuts)).sorted()
                guard cuts.count > 1 else { return [ScreenshotTextLine(text:string,bounds:textBounds,confidence:candidate.confidence)] }
                cuts.append(string.endIndex)
                return (0..<cuts.count-1).compactMap { index in
                    let range = cuts[index]..<cuts[index+1]
                    let text = String(string[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, var box = candidateBox(range) else { return nil }
                    if ScreenshotTextFilter.isUILabel(text) || noise.contains(text) {
                        let boxes = words.filter { range.contains($0.0.lowerBound) }.map(\.1)
                        if !boxes.isEmpty { box = boxes.reduce(CGRect.null) { $0.union($1) } }
                    }
                    return ScreenshotTextLine(text:text,bounds:box,confidence:candidate.confidence)
                }
            }
            let initial = ScreenshotTextFilter.separate(separated.isEmpty ? lines : separated,imageSize:imageSize)
            protectedBounds += initial.icons
            let refined = initial.text.map { line -> ScreenshotTextLine in
                guard ScreenshotTextFilter.isUILabel(line.text) else { return line }
                if prefixPixels == nil { prefixPixels = ScreenshotLayoutObstacles(image:image,size:imageSize) }
                guard let bounds = prefixPixels?.tightText(in:line.bounds,excluding:protectedBounds) else { return line }
                return ScreenshotTextLine(text:line.text,bounds:bounds,confidence:line.confidence)
            }
            let document = ScreenshotDocument(lines:refined,imageSize:imageSize,protectedBounds:protectedBounds)
            timing?(["prepare_seconds":prepared-start,"vision_seconds":recognized-prepared,"geometry_seconds":ProcessInfo.processInfo.systemUptime-recognized])
            return document
        }
        return try await withTaskCancellationHandler(operation: { try await work.value },
                                                      onCancel: { cancellation.cancel();work.cancel() })
    }
    static func recognize(_ url: URL) async throws -> String { try await recognize(.file(url)) }

    @MainActor
    static func beginSnapshot(completion: @escaping (Result<FrozenCapture, Error>) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            completion(.failure(TranslateError.message("截图翻译需要屏幕录制权限，请在设置中授权后重试。"))); return
        }
        let screens = NSScreen.screens.map { screen -> ScreenshotDisplaySpec in
            ScreenshotDisplaySpec(id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                                  frame: screen.frame, scale: screen.backingScaleFactor)
        }
        guard let first = screens.first else { completion(.failure(TranslateError.message("没有可用的屏幕。"))); return }
        let deliver: (Result<FrozenCapture, Error>) -> Void = { result in
            // A native menu may still be tracking. Deliver before dismissing it,
            // through common run-loop modes rather than a MainActor Task.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    guard NSScreen.screens.map(\.frame) == screens.map(\.frame) else { completion(.failure(CancellationError())); return }
                    completion(result)
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        if #available(macOS 14.0, *) {
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                guard let content else { deliver(.failure(error ?? TranslateError.message("无法截取屏幕，请重试。"))); return }
                let collector = ScreenshotCaptureCollector(count: screens.count, completion: deliver)
                for (index, screen) in screens.enumerated() {
                    guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
                        collector.receive(index: index, result: .failure(TranslateError.message("屏幕已变化，请重新截图。"))); continue
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let configuration = SCStreamConfiguration()
                    let size = ScreenshotDisplaySpec.pixelSize(points: filter.contentRect.size,
                                                               scale: max(screen.scale, CGFloat(filter.pointPixelScale)))
                    configuration.width = size.width; configuration.height = size.height
                    configuration.captureResolution = .best; configuration.scalesToFit = false
                    configuration.showsCursor = false
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                        if let image { collector.receive(index: index, result: .success(CapturedDisplay(frame: screen.frame, image: image))) }
                        else { collector.receive(index: index, result: .failure(error ?? TranslateError.message("无法截取屏幕，请重试。"))) }
                    }
                }
            }
        } else {
            let frame = screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
            let rect = CaptureGeometry.displayRect(frame, primaryTop: first.frame.maxY)
            Task.detached {
                do { deliver(.success(FrozenCapture(frame: frame, image: try await legacySnapshot(rect)))) }
                catch { deliver(.failure(error)) }
            }
        }
    }

    @MainActor
    static func capture(snapshot: FrozenCapture, onCaptured: () -> Void) async throws -> String? {
        try Task.checkCancellation()
        let picker = ScreenSelection()
        guard let rect = try await picker.select(snapshot: snapshot),
              let selection = snapshot.crop(rect) else { return nil }
        try Task.checkCancellation()
        onCaptured()
        let text = try await recognize(.image(selection))
        try Task.checkCancellation()
        guard !text.isEmpty else { throw TranslateError.message("没有识别到文字，请重新框选清晰的区域。") }
        return text
    }
    private static func legacySnapshot(_ rect: CGRect) async throws -> CGImage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sonuvi-ocr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("screen.png")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Noninteractive capture does not take focus or dismiss an open menu.
        process.arguments = ["-x", "-r", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let code: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run(); if Task.isCancelled { process.terminate() } }
                catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { if process.isRunning { process.terminate() } })
        try Task.checkCancellation()
        guard code == 0, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TranslateError.message("无法截取屏幕，请检查屏幕录制权限后重试。")
        }
        return image
    }
}

@MainActor
enum LoginManager {
    static var enabled: Bool { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
    static func apply(_ enable: Bool) throws {
        guard enable != enabled else { return }
        if enable {
            let path = Bundle.main.bundlePath
            guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { throw TranslateError.message("开机启动需要先把应用移到「应用程序」，再重新打开。") }
            try SMAppService.mainApp.register()
        } else { try SMAppService.mainApp.unregister() }
    }
}

struct NativeBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    @ViewBuilder func museGlass(_ radius: CGFloat = 18, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.16)))
        }
    }
}

struct MuseHoverStyle: ButtonStyle {
    var radius: CGFloat = 10
    func makeBody(configuration: Configuration) -> some View {
        HoverContent(label: configuration.label, pressed: configuration.isPressed, radius: radius)
    }
    private struct HoverContent<Label: View>: View {
        let label: Label
        let pressed: Bool
        let radius: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) var enabled
        @Environment(\.accessibilityReduceMotion) var reduceMotion
        var body: some View {
            label.background(Color.primary.opacity(enabled ? (pressed ? 0.12 : hovered ? 0.065 : 0) : 0), in: RoundedRectangle(cornerRadius: radius))
                .opacity(enabled ? 1 : 0.38).contentShape(RoundedRectangle(cornerRadius: radius))
                .onHover { hovered = $0 }.animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        }
    }
}
