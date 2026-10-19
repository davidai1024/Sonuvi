// Sonuvi — GPL-3.0.
import AppKit
import Carbon
import SwiftUI

@MainActor
func runPreferenceInteractionTests() async {
    var count = 0
    func check(_ condition: Bool, _ name: String) {
        guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    check(ShortcutSpec.translate.label == "⌥⇧T" && ShortcutSpec.translate.keyCode == UInt32(kVK_ANSI_T), "New translate default matches saved user preference")
    check(ShortcutSpec.read.label == "⌥⇧S" && ShortcutSpec.read.keyCode == UInt32(kVK_ANSI_S), "New read default matches saved user preference")
    check(ShortcutSpec.ocr.label == "⌥⇧R" && ShortcutSpec.ocr.keyCode == UInt32(kVK_ANSI_R), "New screenshot default matches saved user preference")
    check([ShortcutSpec.translate, .read, .ocr].allSatisfy { $0.modifiers == UInt32(optionKey | shiftKey) }, "All new defaults use Option Shift")
    let model = AppModel(); model.previewMode = true
    model.excludedApps = ["test.blocked", "test.other"]
    check(!model.showsSelectionMenu(in: "test.blocked") && model.showsSelectionMenu(in: "test.allowed"), "Positive switch preserves previously hidden app settings")
    model.setSelectionMenu(true, in: "test.blocked")
    check(model.showsSelectionMenu(in: "test.blocked") && model.excludedApps == ["test.other"], "On shows menu and preserves unrelated preferences")
    model.setSelectionMenu(false, in: "test.blocked"); model.setSelectionMenu(false, in: "test.blocked")
    check(!model.showsSelectionMenu(in: "test.blocked") && model.excludedApps.count == 2, "Off hides menu without duplicate entries")
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 140)); window.contentView = container
    let field = ShortcutRecorder.Field(frame: NSRect(x: 20, y: 50, width: 164, height: 34))
    field.saved = ShortcutSpec.translate.label; field.title = field.saved
    container.addSubview(field); window.orderBack(nil)
    var recording = false; var saved: [ShortcutSpec] = []; var pressed: [String] = []
    field.recording = { recording = $0 }; field.change = { saved.append($0) }; field.pressed = { pressed = $0 }
    func key(_ type: NSEvent.EventType, _ code: Int, _ flags: NSEvent.ModifierFlags, _ chars: String) {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
        NSApp.postEvent(event, atStart: false)
    }
    _ = field.accessibilityPerformPress()
    check(recording && field.activeRecording && field.title == field.saved, "Click enters recording while preserving the saved combination")
    check(field.focusRingType == .none && field.bounds.height == 34, "Recorder uses one custom surface without native overlapping focus ring")
    key(.keyDown, kVK_ANSI_T, [], "t"); try? await Task.sleep(nanoseconds: 70_000_000)
    check(recording && saved.isEmpty && field.title == L10n.text("需要修饰键"), "Unmodified letters stay in recording with visible guidance")
    key(.keyDown, kVK_Escape, [], "\u{1b}"); try? await Task.sleep(nanoseconds: 70_000_000)
    check(!recording && saved.isEmpty && field.title == field.saved, "Escape restores the original value without saving")
    _ = field.accessibilityPerformPress()
    key(.keyDown, kVK_ANSI_S, [.option, .shift], "S"); try? await Task.sleep(nanoseconds: 70_000_000)
    check(recording && saved.isEmpty && pressed == ["⌥", "⇧", "S"], "Pressed keys are shown live without firing a new binding")
    key(.keyUp, kVK_ANSI_S, [.option, .shift], "S"); try? await Task.sleep(nanoseconds: 70_000_000)
    check(!recording && saved == [.read], "Releasing the key commits exactly once")
    _ = field.accessibilityPerformPress()
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 280, y: 100), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
    NSApp.postEvent(click, atStart: false); try? await Task.sleep(nanoseconds: 70_000_000)
    check(!recording && saved.count == 1, "Clicking outside cancels recording without changing the binding")
    _ = field.accessibilityPerformPress(); window.makeFirstResponder(nil)
    check(!recording && field.title == field.saved, "Focus loss restores the idle visual state")
    check(!(field as NSView is NSButton), "Recorder has no NSButtonCell to paint the spurious selection band")
    check(ShortcutKeyPreview.glyphs(value: .translate, pressed: ["⌘"]) == ["⌘"], "Live preview replaces old modifiers instead of merging them")
    check(ShortcutKeyPreview.glyphs(value: .read, pressed: []) == ["⌥", "⇧", "S"], "Idle preview follows the selected saved combination")
    let second = ShortcutRecorder.Field(frame: NSRect(x: 190, y: 50, width: 116, height: 32))
    second.saved = ShortcutSpec.ocr.label; second.title = second.saved; container.addSubview(second)
    _ = field.accessibilityPerformPress(); _ = second.accessibilityPerformPress()
    check(!field.activeRecording && second.activeRecording, "Switching fields leaves exactly one recorder active")
    window.makeFirstResponder(nil)
    check(!second.activeRecording, "Leaving the second field cancels its recording")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        field.appearance = NSAppearance(named: appearance); _ = field.accessibilityPerformPress()
        if let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) {
            field.cacheDisplay(in: field.bounds, to: bitmap)
            check(bitmap.pixelsWide > 0 && field.focusRingType == .none, "Custom recorder draws in \(appearance.rawValue) without a native overlay")
        }
        window.makeFirstResponder(nil)
    }
    window.close()
    let metrics = OnboardingLayoutMetrics()
    let host = NSHostingView(rootView: OnboardingLayoutFixture(contentHeight: 180, metrics: metrics))
    let layoutWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    layoutWindow.isReleasedWhenClosed = false; layoutWindow.contentView = host; layoutWindow.orderBack(nil)
    for (viewportHeight, contentHeight) in [(500.0, 180.0), (650.0, 360.0), (420.0, 650.0)] {
        host.rootView = OnboardingLayoutFixture(contentHeight: contentHeight, metrics: metrics)
        layoutWindow.setContentSize(NSSize(width: 420, height: viewportHeight))
        try? await Task.sleep(nanoseconds: 200_000_000); host.layoutSubtreeIfNeeded()
        check(abs(metrics.rect.height - contentHeight) < 1, "Onboarding preserves intrinsic content height \(contentHeight)")
        if contentHeight + 16 <= viewportHeight {
            check(abs(metrics.rect.midY - viewportHeight / 2) < 1, "Short onboarding content centers in viewport \(viewportHeight)")
        } else {
            check(abs(metrics.rect.minY - 8) < 1, "Oversized onboarding content starts at the top and remains scrollable")
        }
    }
    layoutWindow.close()
    // Real SwiftUI rows: validate parent selection gestures do not steal capture.
    let suite = "Sonuvi.PreferenceFixture." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let onboarding = OnboardingState(defaults: defaults); onboarding.go(.shortcuts)
    model.settingsTab = "快捷键"
    model.translateShortcut = .translate; model.readShortcut = .read; model.ocrShortcut = .ocr
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for page in ["settings", "onboarding"] {
        let view: AnyView = page == "settings" ? AnyView(SettingsView(model: model)) : AnyView(OnboardingView(model: model, state: onboarding, requestPermission: { _ in }, restart: {}, complete: {}))
        let actualHost = NSHostingView(rootView: view)
        let actualWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        actualWindow.isReleasedWhenClosed = false; actualWindow.contentView = actualHost; actualWindow.orderBack(nil)
        try? await Task.sleep(nanoseconds: 250_000_000); actualHost.layoutSubtreeIfNeeded()
        let fields = descendants(actualHost).compactMap { $0 as? ShortcutRecorder.Field }
        check(fields.count == 3, "\(page) embeds all three shared recorders")
        let target = fields[1]
        let location = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: actualWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(target.activeRecording && model.recordingShortcut, "\(page) row gesture leaves clicked recorder active")
        check(target.isSelected && fields.filter { $0.isSelected }.count == 1, "\(page) highlights exactly the clicked row")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.control, .option], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: actualWindow.windowNumber, context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: UInt16(kVK_ANSI_L))!
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
        check(!target.activeRecording && !model.recordingShortcut && model.readShortcut.label == "⌃⌥L", "\(page) commits through the binding and ends capture")
        _ = target.accessibilityPerformPress()
        actualHost.rootView = AnyView(Color.clear)
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(!model.recordingShortcut, "\(page) navigation cancels recording and restores shortcut availability")
        actualWindow.close()
    }
    var draft = ""
    let binding = Binding<String>(get: { draft }, set: { draft = $0 })
    let apiHost = NSHostingView(rootView: APIKeyField(placeholder: "Synthetic fixture", text: binding).frame(width: 260, height: 28).frame(width: 400, height: 150))
    let apiWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
    apiWindow.isReleasedWhenClosed = false; apiWindow.contentView = apiHost; apiWindow.orderBack(nil)
    try? await Task.sleep(nanoseconds: 150_000_000); apiHost.layoutSubtreeIfNeeded()
    let apiField = descendants(apiHost).compactMap { $0 as? APIKeyField.Field }.first!
    func apiKey(_ code: Int, chars: String) {
        NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: apiWindow.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!, atStart: false)
    }
    for action in ["escape", "outside", "return"] {
        apiWindow.makeKey(); apiField.selectText(nil)
        apiKey(kVK_ANSI_A, chars: "a")
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(apiField.currentEditor() != nil && !draft.isEmpty, "API field accepts draft input before \(action)")
        let before = draft
        if action == "outside" {
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: apiWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
        } else { apiKey(action == "escape" ? kVK_Escape : kVK_Return, chars: action == "escape" ? "\u{1b}" : "\r") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(apiField.currentEditor() == nil && draft == before, "API \(action) exits editing and preserves the unsaved draft")
        apiHost.rootView = APIKeyField(placeholder: "Updated fixture", text: binding).frame(width: 260, height: 28).frame(width: 400, height: 150)
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(apiField.currentEditor() == nil, "SwiftUI refresh does not steal API focus after \(action)")
    }
    apiWindow.close()
    let savedLanguage = AppLocalization.shared.language
    for language in [AppLanguage.chinese, .english] {
        AppLocalization.shared.language = language
        let tip = NSHostingController(rootView: MenuBarWelcomeTip(close: {}))
        let size = tip.view.fittingSize
        check(abs(size.width - 320) < 1 && size.height >= 120 && size.height <= 230, "Welcome tip fits localized content without a fixed-height blank footer: \(language.rawValue)")
        let fixture = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        fixture.isReleasedWhenClosed = false; fixture.contentViewController = tip
        fixture.orderBack(nil)
        try? await Task.sleep(nanoseconds: 120_000_000)
        check(abs(tip.view.fittingSize.height - size.height) < 1, "Welcome tip height stays stable after layout: \(language.rawValue)")
        fixture.close()
    }
    AppLocalization.shared.language = savedLanguage
    print("PASS: \(count) preference interaction checks")
}

@MainActor private final class OnboardingLayoutMetrics { var rect = CGRect.zero }
private struct OnboardingBoundsKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}
private struct OnboardingLayoutFixture: View {
    let contentHeight: CGFloat
    let metrics: OnboardingLayoutMetrics
    var body: some View {
        OnboardingCenteredScroll {
            Color.blue.frame(height: contentHeight)
                .background(GeometryReader { geometry in Color.clear.preference(key: OnboardingBoundsKey.self, value: geometry.frame(in: .named("fixture"))) })
        }.coordinateSpace(name: "fixture")
            .onPreferenceChange(OnboardingBoundsKey.self) { metrics.rect = $0 }
    }
}
