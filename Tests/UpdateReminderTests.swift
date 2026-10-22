// Sonuvi — GPL-3.0. No production preferences, TCC changes, network requests or installs.
import AppKit
import SwiftUI
import Sparkle

@MainActor
func runUpdateReminderTests() async {
    var count = 0
    func check(_ value: Bool, _ title: String) {
        guard value else { fputs("FAIL: \(title)\n", stderr); exit(1) }
        count += 1; print("PASS: \(title)")
    }
    let suite = "Sonuvi.UpdateReminderTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("preserved", forKey: "modelPreference")
    let updates = AppUpdates(defaults: defaults, currentBuild: "45")
    check(!updates.hasUpdate && !updates.panelReminderVisible(), "Fresh launch has no update badge or panel reminder")
    for selector in ["updater:userDidMakeChoice:forUpdate:state:", "updater:willDownloadUpdate:withRequest:", "updater:didDownloadUpdate:", "userDidCancelDownload:", "standardUserDriverWillFinishUpdateSession"] {
        check(updates.responds(to: NSSelectorFromString(selector)), "Sparkle callback is actually registered: " + selector)
    }
    updates.recordUpdate(version: "0.4.33", build: "46")
    check(updates.hasUpdate && updates.panelReminderVisible(), "Detected version appears in menu and panel")
    check(updates.menuTitle == "更新至 0.4.33…" && updates.panelTitle == "有更新", "New release copy includes version without claiming a download")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let today = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
    updates.dismissPanelReminder(now: today, calendar: calendar)
    let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
    check(updates.hasUpdate && !updates.panelReminderVisible(at: today), "Closing panel reminder leaves menu badge and version available")
    check(!updates.panelReminderVisible(at: nextDay.addingTimeInterval(-1)) && updates.panelReminderVisible(at: nextDay), "Panel stays dismissed until the next calendar day")
    let reopened = AppUpdates(defaults: defaults, currentBuild: "45")
    check(reopened.hasUpdate && !reopened.panelReminderVisible(at: today), "Closing and reopening the app preserves today's dismissal and menu reminder")
    updates.finishSession()
    check(updates.hasUpdate, "Finishing a Sparkle session does not lose an uninstalled update")
    updates.updatePhase(.downloading)
    check(updates.panelTitle == "下载中" && !updates.menuTitle.contains("重启"), "Active download does not offer restart")
    updates.updatePhase(.verifying)
    check(updates.panelTitle == "校验中" && !updates.detail.contains("已下载"), "Download completion still waits for verification")
    updates.handleChoice(.dismiss, stage: .downloaded)
    check(updates.hasUpdate && updates.panelTitle == "重启并更新", "Deferring a downloaded update retains the restart action")
    let restarted = AppUpdates(defaults: defaults, currentBuild: "45")
    check(restarted.hasUpdate && restarted.phase == .available, "Cached reminder never claims an executable is ready after restart")
    updates.handleChoice(.skip, stage: .notDownloaded)
    check(!updates.hasUpdate && defaults.data(forKey: "updates.reminder") == nil, "Skipping this version clears every reminder and its cache")
    updates.recordUpdate(version: "0.4.34", build: "47")
    check(updates.hasUpdate, "A later version can be offered after skipping the earlier one")
    let installed = AppUpdates(defaults: defaults, currentBuild: "47")
    check(!installed.hasUpdate, "Successful upgrade removes the cached badge")
    updates.clearReminder()
    check(!updates.hasUpdate && defaults.string(forKey: "modelPreference") == "preserved", "No-update result removes reminders without touching other preferences")
    check(UpdateStatusBadge(frame: NSRect(x: 0, y: 0, width: 5, height: 5)).hitTest(.zero) == nil, "Menu badge never intercepts menu clicks")

    let previousLanguage = AppLocalization.shared.language
    defer { AppLocalization.shared.language = previousLanguage }
    defaults.removeObject(forKey: "updates.panelDismissedUntil")
    let display = AppUpdates(defaults: defaults, currentBuild: "45")
    let model = AppModel(updates: display); model.previewMode = true
    model.source = "Select any text to translate it."; model.result = "选中文字即可翻译。"
    model.sourceApp = "com.apple.finder"
    for language in [AppLanguage.chinese, .english] {
        AppLocalization.shared.language = language
        for ready in [false, true] {
            display.recordUpdate(version: "0.4.33", build: "46", phase: ready ? .ready : .available)
            let host = NSHostingView(rootView: LocalizedRoot(content: TranslateView(model: model)).ignoresSafeArea())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.backgroundColor = .windowBackgroundColor; window.contentView = host
            host.appearance = NSAppearance(named: ready ? .darkAqua : .aqua)
            window.orderBack(nil); try? await Task.sleep(nanoseconds: 200_000_000); host.layoutSubtreeIfNeeded()
            check(host.frame.width == 360, "Update label preserves narrow translation width: \(language.rawValue), ready=\(ready)")
            if let index = CommandLine.arguments.firstIndex(of: "--snapshots"), CommandLine.arguments.indices.contains(index + 1),
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1]); try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("update-\(language.rawValue)-\(ready ? "ready" : "available").png"))
                let renderer = ImageRenderer(content: LocalizedRoot(content: TranslateView(model: model).toolbar)
                    .frame(width: 360).environment(\.colorScheme, ready ? .dark : .light)
                    .background(ready ? Color(red: 0.15, green: 0.15, blue: 0.16) : Color(red: 0.96, green: 0.96, blue: 0.97)))
                renderer.scale = 2
                if let image = renderer.nsImage, let data = image.tiffRepresentation, let imageBitmap = NSBitmapImageRep(data: data) {
                    try? imageBitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("toolbar-\(language.rawValue)-\(ready ? "ready" : "available").png"))
                }
            }
            window.close()
        }
    }
    print("PASS: \(count) update reminder checks")
}

// Launched only from a separately signed, isolated bundle with a synthetic version.
@MainActor
func runUpdateConnectionTest() async {
    guard Bundle.main.bundleIdentifier?.hasPrefix("com.wusir.sonuvi.updatenoticefixture.") == true else {
        fputs("Refusing network fixture under production identity\n", stderr); exit(1)
    }
    let updates = AppUpdates()
    updates.start(preview: false)
    guard let updater = updates.updater else { exit(1) }
    updater.automaticallyChecksForUpdates = false
    updater.checkForUpdatesInBackground()
    let deadline = Date().addingTimeInterval(45)
    while !(updates.canCheck && (updates.hasUpdate || updates.notice == "已是最新版本。")) && Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    print("STATE: available=\(updates.availableVersion ?? "none"), canCheck=\(updates.canCheck), phase=\(updates.phase), visibleWindows=\(NSApp.windows.filter { $0.isVisible }.count), notice=\(updates.notice)")
    let expectUpdate = CommandLine.arguments.contains("--expect-update")
    guard updates.hasUpdate == expectUpdate,
          (expectUpdate || updates.notice == "已是最新版本。"),
          NSApp.windows.allSatisfy({ !$0.isVisible }),
          updates.phase == .available,
          !expectUpdate || (updates.panelReminderVisible() && updates.canCheck) else {
        fputs("FAIL: Real updater reminder integration\n", stderr); exit(1)
    }
    print("PASS: Signed online feed through AppUpdates; update=\(updates.availableVersion ?? "none"), gentle=true, canCheck=\(updates.canCheck)")
}
