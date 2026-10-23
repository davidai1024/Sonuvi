// Synthetic, app-owned native menu. Never opens or reads another app's menu.
import AppKit
import Carbon

@MainActor
func runMenuCaptureTest() {
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
        fputs("Menu capture test requires existing Accessibility and screen capture access; no permission is requested.\n", stderr); exit(2)
    }
    let shortcuts = GlobalShortcuts()
    let spec = ShortcutSpec(keyCode: 80, modifiers: UInt32(cmdKey | optionKey | controlKey), label: "Test F19")
    guard shortcuts.install([ShortcutSpec(keyCode: 79, modifiers: spec.modifiers, label: "Test F18"), ShortcutSpec(keyCode: 90, modifiers: spec.modifiers, label: "Test F20"), spec]) else { exit(3) }
    let menu = NSMenu(title: "Synthetic Screenshot Menu")
    menu.addItem(withTitle: "Hello David", action: nil, keyEquivalent: "")
    menu.addItem(withTitle: "公司练习", action: nil, keyEquivalent: "")
    let screen = NSScreen.main!.frame
    let point = CGPoint(x: screen.midX, y: screen.midY)
    var receivedWhileTracking = false
    var savedWhileTracking = false
    var calls = 0
    var snapshot: FrozenCapture?
    var failure: Error?
    shortcuts.onOCR = {
        calls += 1
        receivedWhileTracking = MenuTrackingCapture.isTracking
        OCRService.beginSnapshot { result in
            savedWhileTracking = MenuTrackingCapture.isTracking
            switch result { case .success(let value): snapshot = value; case .failure(let error): failure = error }
            MenuTrackingCapture.finish()
        }
    }
    let press = Timer(timeInterval: 0.4, repeats: false) { _ in
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(spec.keyCode), keyDown: down)!
            event.flags = [.maskCommand, .maskAlternate, .maskControl]
            event.post(tap: .cghidEventTap)
        }
    }
    let timeout = Timer(timeInterval: 6, repeats: false) { _ in menu.cancelTrackingWithoutAnimation() }
    RunLoop.main.add(press, forMode: .common); RunLoop.main.add(timeout, forMode: .common)
    NSApp.activate(ignoringOtherApps: true)
    menu.popUp(positioning: nil, at: point, in: nil)
    press.invalidate(); timeout.invalidate()
    guard receivedWhileTracking, savedWhileTracking, calls == 1, let snapshot else {
        fputs("FAIL: callbackBeforeClose=\(receivedWhileTracking), snapshotBeforeClose=\(savedWhileTracking), calls=\(calls), error=\(String(describing: failure))\n", stderr); exit(1)
    }
    print("PASS: configured screenshot chord is delivered and frozen while native menu remains open")
    let crop = CGRect(x: point.x - 30, y: point.y - 220, width: 400, height: 260)
    guard let image = snapshot.crop(crop) else { exit(1) }
    Task { @MainActor in
        do {
            let picker = ScreenSelection()
            let selection = Task { try await picker.select(snapshot: snapshot) }
            let drag = Timer(timeInterval: 0.3, repeats: false) { _ in
                let top = NSScreen.screens.first!.frame.maxY
                for (kind, location) in [(CGEventType.leftMouseDown, CGPoint(x: crop.minX, y: top - crop.maxY)),
                                         (.leftMouseDragged, CGPoint(x: crop.maxX, y: top - crop.minY)),
                                         (.leftMouseUp, CGPoint(x: crop.maxX, y: top - crop.minY))] {
                    CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            }
            let limit = Timer(timeInterval: 3, repeats: false) { _ in selection.cancel() }
            RunLoop.main.add(drag, forMode: .common); RunLoop.main.add(limit, forMode: .common)
            defer { drag.invalidate(); limit.invalidate() }
            guard let rect = try await selection.value, rect == crop else {
                fputs("FAIL: frozen menu selection overlay did not receive drag\n", stderr); exit(1)
            }
            print("PASS: selection overlay accepts drag immediately after frozen menu capture")
            let text = try await OCRService.recognize(.image(image))
            guard text.contains("Hello David"), text.contains("公司") else {
                fputs("FAIL: frozen menu labels missing\n", stderr); exit(1)
            }
            // Give any queued Carbon delivery time to surface; it must not fire twice.
            try await Task.sleep(nanoseconds: 250_000_000)
            guard calls == 1 else { fputs("FAIL: duplicate screenshot callback\n", stderr); exit(1) }
            withExtendedLifetime(shortcuts) {}
            print("PASS: both native menu labels survive closing and OCR; shortcut fires once")
            exit(0)
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
