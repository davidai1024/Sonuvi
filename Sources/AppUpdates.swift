// Sonuvi — GPL-3.0. Sparkle owns download, validation, atomic replacement and relaunch.
import AppKit
import SwiftUI
import Sparkle

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var notice = ""
    var onChange: (() -> Void)?
    var beforeInstall: (() -> Void)?
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var menuTitle: String { availableVersion.map { "发现新版本 \($0)…" } ?? "检查更新…" }

    func start(preview: Bool) {
        guard !preview, controller == nil else { return }
        // Distribution settings are bundled, never accepted from user defaults or a remote response.
        guard Bundle.main.object(forInfoDictionaryKey: "SonuviFixedSigning") as? Bool == true,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host == "sonuvi.davidai1024.com",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            notice = "此构建未启用应用更新，请从官网下载新版。"; return
        }
        let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller = value
        do { try value.updater.start() }
        catch { notice = "更新服务未能启动，请稍后重试。"; return }
        for keyPath in [\SPUUpdater.canCheckForUpdates, \SPUUpdater.automaticallyChecksForUpdates] {
            observations.append(value.updater.observe(keyPath, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observations.append(value.updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }
    private func refresh() {
        guard let updater = controller?.updater else { return }
        canCheck = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastChecked = updater.lastUpdateCheckDate
        onChange?()
    }
    func check() {
        guard canCheck else { return }
        notice = ""
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        refresh()
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString; notice = ""; refresh()
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil; notice = "已是最新版本。"; refresh()
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle displays the precise error for manual checks; background failures stay quiet.
        let nsError = error as NSError
        if nsError.domain != SUSparkleErrorDomain || nsError.code != SUError.noUpdateError.rawValue {
            notice = "暂时无法检查更新，请检查网络后重试。"
        }
        refresh()
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        beforeInstall?()
    }
    // Scheduled checks only set the menu/settings reminder. No focus stealing or notification permission.
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString; refresh()
    }
    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil; refresh()
    }
}

struct AppUpdateSettings: View {
    @ObservedObject var updates: AppUpdates
    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Sonuvi \(updates.version)", detail: updates.availableVersion.map { "新版本 \($0) 已就绪" } ?? "更新应用会保留设置、API Key 和已下载的朗读模型。", symbol: "arrow.triangle.2.circlepath") {
                Button(L10n.text(updates.availableVersion == nil ? "检查更新…" : "查看更新…")) { updates.check() }
                    .disabled(!updates.canCheck)
            }
            Divider().opacity(0.35).padding(.leading, 50).padding(.trailing, 16)
            SettingsRow(title: "自动检查更新", detail: "每天检查一次，有新版本时提醒；点击后再下载和安装。", symbol: "clock.arrow.circlepath") {
                Toggle(L10n.text("自动检查更新"), isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticChecks($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.cyan).disabled(!updates.canCheck)
            }
            if !updates.notice.isEmpty {
                LText(updates.notice).font(MuseLayout.detail).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
    }
}
