// Sonuvi — GPL-3.0. Exercise the full window, including optional recovery UI.
import AppKit
import SwiftUI

@MainActor private final class OnboardingWindowMetrics {
    var frames: [OnboardingLayoutPart: CGRect] = [:]
}

@MainActor
func runOnboardingLayoutTests() async {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        checks += 1; print("PASS: \(message)")
    }
    let previousLanguage = AppLocalization.shared.language
    defer { AppLocalization.shared.language = previousLanguage }
    for language in [AppLanguage.chinese, .english] {
        AppLocalization.shared.language = language
        for (width, height, returning, migration) in [(1080.0, 660.0, false, false), (900.0, 600.0, false, false), (1080.0, 800.0, false, false), (1080.0, 660.0, true, false), (900.0, 600.0, false, true), (1080.0, 660.0, true, true)] {
            let suite = "Sonuvi.OnboardingLayout." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let state = OnboardingState(defaults: defaults); state.go(.permissions)
            if returning { state.preparePermissionReturn() }
            let model = AppModel(); model.previewMode = true
            model.language = language; model.permissionGranted = false; model.screenPermission = false
            model.permissionMigrationPending = migration
            let metrics = OnboardingWindowMetrics()
            let content = OnboardingView(model: model, state: state, requestPermission: { _ in }, restart: {}, complete: {})
                .onPreferenceChange(OnboardingLayoutFrames.self) { metrics.frames = $0 }
            let host = NSHostingView(rootView: LocalizedRoot(content: content).ignoresSafeArea())
            if #available(macOS 14.0, *) { host.safeAreaRegions = [] }
            let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.toolbar = NSToolbar(identifier: "OnboardingLayoutFixture"); window.toolbarStyle = .unified; window.titlebarSeparatorStyle = .none
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = host; window.orderBack(nil)
            try? await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
            let label = "\(language.rawValue)-\(Int(width))x\(Int(height))-\(returning ? "return" : "initial")-\(migration ? "migration" : "ordinary")"
            guard let introduction = metrics.frames[.introduction], let permissions = metrics.frames[.permissions],
                  let content = metrics.frames[.content], let viewport = metrics.frames[.viewport] else {
                check(false, "Complete window reports all layout regions: \(label)"); return
            }
            // Initial permissions have no recovery controls: their actual
            // visible group must be centered, not a larger invisible wrapper.
            let visible = returning || migration ? content : permissions
            print("LAYOUT: \(label) introduction=\(introduction) visible=\(visible) viewport=\(viewport)")
            check(abs(visible.midY - viewport.midY) < 1, "Visible permissions center in the complete window: \(label)")
            check(abs(visible.midY - introduction.midY) < 1, "Permission group and introduction share their vertical center: \(label)")
            check(viewport.insetBy(dx: -0.5, dy: -0.5).contains(visible), "Permission controls remain fully visible: \(label)")
            check(returning || migration || abs(content.height - permissions.height) < 1, "Initial permissions reserve no invisible recovery height: \(label)")
            window.close(); defaults.removePersistentDomain(forName: suite)
        }
    }
    print("PASS: \(checks) complete onboarding layout checks")
}
