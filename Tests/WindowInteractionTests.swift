// Synthetic windows and injected credentials; no production key is modified.
import AppKit

@MainActor
func runWindowInteractionTests() {
    var count = 0
    func check(_ value: Bool, _ title: String) {
        guard value else { fputs("FAIL: \(title)\n", stderr); exit(1) }
        count += 1; print("PASS: \(title)")
    }
    let state = CredentialWindowPresentation()
    let window = SettingsWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
    window.makeKeyAndOrderFront(nil)
    state.begin(windows: [window]); window.orderOut(nil); state.finish()
    check(window.isVisible && !state.isActive, "Authorization restores its original settings window")
    state.begin(windows: [window]); window.performClose(nil); state.finish()
    check(!window.isVisible, "Explicitly closed settings is not reopened after authorization")
    state.begin(windows: [window]); state.finish()
    check(!window.isVisible, "Authorization without a visible window never opens settings")

    let model = AppModel()
    var events: [String] = []
    model.beginCredentialInteraction = { events.append("begin") }
    model.endCredentialInteraction = { events.append("finish") }
    do { try model.authorizeAPIKeyAccess { _ in events.append("read"); return "synthetic" } }
    catch { check(false, "Synthetic access succeeds") }
    check(events == ["begin", "read", "finish"], "Successful authorization brackets window restoration")
    events.removeAll()
    do { try model.authorizeAPIKeyAccess { _ in events.append("read"); throw KeyAccessError.authorizationRequired } }
    catch {}
    check(events == ["begin", "read", "finish"] && model.keyAccessRequired, "Denied authorization restores window without claiming access")

    var calls: [String] = []
    do {
        let current = try CredentialMigration.read(current: { "new" }, legacy: { calls.append("legacy"); return "old" }, persist: { _ in calls.append("persist") })
        check(current == "new" && calls.isEmpty, "Current credential never rereads old key or requests migration")
        let migrated = try CredentialMigration.read(current: { nil }, legacy: { calls.append("legacy"); return "old" }, persist: { value in calls.append(value) })
        check(migrated == "old" && calls == ["legacy", "old"], "Successful legacy access copies only the authorized value")
        calls.removeAll()
        do {
            _ = try CredentialMigration.read(current: { throw KeyAccessError.authorizationRequired }, legacy: { calls.append("legacy"); return "old" }, persist: { _ in calls.append("persist") })
            check(false, "Denied current credential must throw")
        } catch { check(calls.isEmpty, "Denied current credential cannot fall back to stale key") }
        do {
            _ = try CredentialMigration.read(current: { nil }, legacy: { throw KeyAccessError.authorizationRequired }, persist: { _ in calls.append("persist") })
            check(false, "Denied legacy credential must throw")
        } catch { check(calls.isEmpty, "Denied legacy credential is never copied") }
        let value = try CredentialMigration.read(current: { nil }, legacy: { "authorized" }, persist: { _ in throw KeyAccessError.unavailable(-1) })
        check(value == "authorized", "Failed migration retains authorized session without deleting old key")
    } catch { check(false, "Unexpected credential test failure") }
    let delegate = AppDelegate()
    delegate.model.updates.beginManualPresentation()
    check(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) && delegate.settings == nil,
          "Updater activation cannot create a settings window")
    delegate.model.updates.clearReminder()
    check(delegate.model.updates.isPresentingManualCheck, "No-update result keeps reopen suppression until dialog closes")
    delegate.model.updates.finishSession()
    check(!delegate.model.updates.isPresentingManualCheck, "Closing update dialog ends temporary suppression")
    print("PASS: \(count) credential and window interaction checks")
}

@MainActor
func runManualUpdateDialogTest() async {
    let updates = AppUpdates()
    let settings = SettingsWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    settings.title = "Synthetic Settings"; settings.isReleasedWhenClosed = false
    settings.orderOut(nil)
    updates.start(preview: false)
    for _ in 0..<40 {
        if updates.canCheck { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    var sawDialog = false
    // Sparkle's NSAlert uses a modal run loop, so a MainActor Task cannot
    // acknowledge it. Observe in common modes just as a real button click does.
    let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard !settings.isVisible else { fputs("FAIL: checking updates opened settings\n", stderr); exit(1) }
            if let dialog = NSApp.windows.first(where: { $0.isVisible && $0 !== settings }) {
                guard updates.isPresentingManualCheck else { fputs("FAIL: update dialog lost reopen guard\n", stderr); exit(1) }
                func buttons(_ view: NSView) -> [NSButton] {
                    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
                }
                func labels(_ view: NSView) -> [String] {
                    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
                }
                if let content = dialog.contentView,
                   labels(content).contains(where: { $0.localizedCaseInsensitiveContains("up to date") || $0.contains("最新") }),
                   let button = buttons(content).first(where: { $0.keyEquivalent == "\r" || $0.title == "OK" || $0.title == "确定" }) {
                    sawDialog = true; button.performClick(nil)
                }
            }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .modalPanel)
    defer { timer.invalidate() }
    updates.check()
    for _ in 0..<200 {
        if sawDialog { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    for _ in 0..<40 {
        if !updates.isPresentingManualCheck { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    guard sawDialog, !settings.isVisible, !updates.isPresentingManualCheck else {
        fputs("FAIL: manual no-update dialog lifecycle\n", stderr); exit(1)
    }
    print("PASS: real manual no-update check shows and dismisses only its result dialog; settings remains closed")
}
