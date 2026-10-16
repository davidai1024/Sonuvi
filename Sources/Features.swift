// Sonuvi — GPL-3.0.
import AppKit
import SwiftUI
import Vision
import ServiceManagement
import Carbon

enum AppearanceMode: String, CaseIterable { case system = "跟随系统", light = "浅色", dark = "深色" }

struct ShortcutSpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    static let translate = ShortcutSpec(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥T")
    static let read = ShortcutSpec(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥R")
    static let ocr = ShortcutSpec(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥O")
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
    var onRecording: (Bool) -> Void = { _ in }
    final class Field: NSButton {
        var change: ((ShortcutSpec) -> Void)?
        var saved = ""
        var recording: ((Bool) -> Void)?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var active = false
        var activeRecording: Bool { active }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { beginRecording() }
        override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
        private func beginRecording() {
            guard !active, window?.makeFirstResponder(self) == true else { return }
            active = true; title = "按下组合键…"; recording?(true)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.active, event.window === self.window else { return event }
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
            title = saved; recording?(false)
        }
        private func capture(_ event: NSEvent) {
            if event.keyCode == 53 { finishRecording(); window?.makeFirstResponder(nil); return }
            if let spec = ShortcutSpec.from(event) {
                // End capture first; commit synchronously registers and persists,
                // then updateNSView supplies the accepted or rolled-back label.
                finishRecording(); change?(spec); window?.makeFirstResponder(nil)
            } else { title = "⌃ / ⌥ / ⌘ + 字母或数字" }
        }
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
        let field = Field(); field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium); field.bezelStyle = .rounded; field.isBordered = true
        field.toolTip = "点击录制快捷键；Esc 取消。录制成功后立即生效。"
        return field
    }
    func updateNSView(_ field: Field, context: Context) { field.saved = value.label; if !field.activeRecording { field.title = value.label }; field.change = { value = $0 }; field.recording = onRecording }
}

enum WindowGeometry {
    static func origin(near point: NSPoint, size: NSSize, visible frame: NSRect) -> NSPoint {
        NSPoint(x: max(frame.minX + 8, min(point.x + 14, frame.maxX - size.width - 8)),
                y: max(frame.minY + 8, min(point.y - size.height - 12, frame.maxY - size.height - 8)))
    }
}

enum OCRService {
    static func recognize(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(url: url)
            try handler.perform([request])
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
    @MainActor
    static func capture() async throws -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            throw TranslateError.message("截图翻译需要屏幕录制权限，请在设置中授权后重试。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("musetranslate-ocr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("selection.png")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-r", file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let code: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { if process.isRunning { process.terminate() } })
        try Task.checkCancellation()
        guard code == 0, FileManager.default.fileExists(atPath: file.path) else { return nil }
        let text = try await recognize(file)
        try Task.checkCancellation()
        guard !text.isEmpty else { throw TranslateError.message("没有识别到文字，请重新框选清晰的区域。") }
        return text
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
