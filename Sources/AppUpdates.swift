// Sonuvi — GPL-3.0. Sparkle owns download, validation, atomic replacement and relaunch.
import AppKit
import SwiftUI
import Sparkle

struct AppUpdateReminder: Codable, Equatable {
    let version: String
    let build: String
}
enum AppUpdatePhase { case available, downloading, verifying, ready, installing }

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var reminder: AppUpdateReminder?
    @Published private(set) var phase: AppUpdatePhase = .available
    @Published private(set) var panelDismissedUntil: Date?
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var notice = ""
    var onChange: (() -> Void)?
    var beforeInstall: (() -> Void)?
    private let defaults: UserDefaults
    private var panelTimer: Timer?
    private(set) var updater: SPUUpdater?
    private var userDriver: AppUpdateUserDriver?
    private var observations: [NSKeyValueObservation] = []
    var availableVersion: String? { reminder?.version }
    var hasUpdate: Bool { reminder != nil }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var panelTitle: String {
        switch phase {
        case .available: return "有更新"
        case .downloading: return "下载中"
        case .verifying: return "校验中"
        case .ready: return "重启并更新"
        case .installing: return "安装中"
        }
    }
    var menuTitle: String {
        guard let version = availableVersion else { return "检查更新…" }
        switch phase {
        case .available: return "更新至 \(version)…"
        case .downloading: return "查看更新下载进度…"
        case .verifying: return "正在校验更新…"
        case .ready: return "重启并更新至 \(version)…"
        case .installing: return "正在安装更新…"
        }
    }
    var detail: String {
        guard let version = availableVersion else { return "更新应用会保留设置、API Key 和已下载的朗读模型。" }
        switch phase {
        case .available: return "新版本 \(version) 可下载"
        case .downloading: return "正在下载新版本 \(version)"
        case .verifying: return "正在校验新版本 \(version)"
        case .ready: return "新版本 \(version) 已下载，重启后完成更新。"
        case .installing: return "正在安装新版本 \(version)"
        }
    }
    init(defaults: UserDefaults = .standard, currentBuild: String? = nil) {
        self.defaults = defaults
        super.init()
        // Cache only the reminder, never executable URLs or installation authority.
        // Download readiness belongs to Sparkle and must be re-established each launch.
        let build = currentBuild ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        if let data = defaults.data(forKey: "updates.reminder"),
           let saved = try? JSONDecoder().decode(AppUpdateReminder.self, from: data),
           saved.build.compare(build, options: .numeric) == .orderedDescending {
            reminder = saved
        } else { defaults.removeObject(forKey: "updates.reminder") }
        panelDismissedUntil = defaults.object(forKey: "updates.panelDismissedUntil") as? Date
        schedulePanelReminder()
    }
    deinit { panelTimer?.invalidate() }
    func panelReminderVisible(at date: Date = Date()) -> Bool {
        hasUpdate && (panelDismissedUntil == nil || panelDismissedUntil! <= date)
    }
    func dismissPanelReminder(now: Date = Date(), calendar: Calendar = .current) {
        panelDismissedUntil = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        defaults.set(panelDismissedUntil, forKey: "updates.panelDismissedUntil")
        schedulePanelReminder(); onChange?()
    }
    private func schedulePanelReminder() {
        panelTimer?.invalidate(); panelTimer = nil
        guard let until = panelDismissedUntil, until > Date() else { return }
        let timer = Timer(timeInterval: until.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panelDismissedUntil = nil
                self.defaults.removeObject(forKey: "updates.panelDismissedUntil")
                self.onChange?()
            }
        }
        panelTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func recordUpdate(version: String, build: String, phase: AppUpdatePhase = .available) {
        let value = AppUpdateReminder(version: version, build: build)
        reminder = value; self.phase = phase; notice = ""
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "updates.reminder") }
        refresh()
    }
    func clearReminder() {
        reminder = nil; phase = .available
        defaults.removeObject(forKey: "updates.reminder"); refresh()
    }
    func updatePhase(_ value: AppUpdatePhase) { phase = value; refresh() }
    func finishSession() {
        // Dismissal / temporary errors do not mean the available version disappeared.
        // An explicit skip or a successful no-update check clears it separately.
        refresh()
    }
    func start(preview: Bool) {
        guard !preview, updater == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SonuviFixedSigning") as? Bool == true,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host == "sonuvi.davidai1024.com",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            notice = "此构建未启用应用更新，请从官网下载新版。"; return
        }
        let driver = AppUpdateUserDriver(hostBundle: .main, delegate: self)
        driver.onReady = { [weak self] in self?.updatePhase(.ready) }
        driver.onInstalling = { [weak self] in self?.updatePhase(.installing) }
        let value = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        userDriver = driver; updater = value
        do { try value.start() }
        catch { notice = "更新服务未能启动，请稍后重试。"; return }
        for keyPath in [\SPUUpdater.canCheckForUpdates, \SPUUpdater.automaticallyChecksForUpdates] {
            observations.append(value.observe(keyPath, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observations.append(value.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }
    private func refresh() {
        if let updater {
            canCheck = updater.canCheckForUpdates
            automaticallyChecks = updater.automaticallyChecksForUpdates
            lastChecked = updater.lastUpdateCheckDate
        }
        onChange?()
    }
    func check() {
        guard canCheck else { return }
        notice = ""
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
    }
    func setAutomaticChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
        refresh()
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        recordUpdate(version: item.displayVersionString, build: item.versionString)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        clearReminder(); notice = "已是最新版本。"; refresh()
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain != SUSparkleErrorDomain || nsError.code != SUError.noUpdateError.rawValue {
            notice = "暂时无法检查更新，请检查网络后重试。"
            phase = .available
        }
        refresh()
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        handleChoice(choice, stage: state.stage)
    }
    func handleChoice(_ choice: SPUUserUpdateChoice, stage: SPUUserUpdateStage) {
        if choice == .skip { clearReminder(); return }
        if choice == .dismiss {
            updatePhase(stage == .notDownloaded ? .available : .ready)
            dismissPanelReminder()
        }
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) { updatePhase(.downloading) }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { updatePhase(.verifying) }
    func userDidCancelDownload(_ updater: SPUUpdater) { updatePhase(.available) }
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) { updatePhase(.available) }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        beforeInstall?()
    }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        recordUpdate(version: update.displayVersionString, build: update.versionString,
                     phase: state.stage == .notDownloaded ? .available : .ready)
    }
    func standardUserDriverWillFinishUpdateSession() { finishSession() }
}

// Observe Sparkle's actual ready/install UI stages; keep all of its standard UI and validation.
@MainActor
final class AppUpdateUserDriver: SPUStandardUserDriver {
    var onReady: (() -> Void)?
    var onInstalling: (() -> Void)?
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onReady?(); super.showReady(toInstallAndRelaunch: reply)
    }
    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        onInstalling?()
        super.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }
}

// Separate from the template image so macOS retains its native light/dark rendering.
final class UpdateStatusBadge: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

struct AppUpdateNotice: View {
    @ObservedObject var updates: AppUpdates
    var body: some View {
        if updates.panelReminderVisible() {
            HStack(spacing: 0) {
                Button { updates.check() } label: {
                    LText(updates.panelTitle).font(.system(size: 10, weight: .medium))
                        .padding(.leading, 9).padding(.trailing, 5).frame(height: 24)
                        .contentShape(Rectangle())
                }.disabled(!updates.canCheck)
                    .help(L10n.text(updates.menuTitle))
                    .accessibilityLabel(L10n.text(updates.menuTitle))
                    .accessibilityIdentifier("translation.update")
                Button { updates.dismissPanelReminder() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 22, height: 24).contentShape(Rectangle())
                }.help(L10n.text("今天不再提示"))
                    .accessibilityLabel(L10n.text("今天不再提示"))
                    .accessibilityIdentifier("translation.update-dismiss")
            }.buttonStyle(.plain).fixedSize()
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.09), in: Capsule())
                .padding(.trailing, 6)
        }
    }
}

struct AppUpdateSettings: View {
    @ObservedObject var updates: AppUpdates
    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Sonuvi \(updates.version)", detail: updates.detail, symbol: "arrow.triangle.2.circlepath") {
                Button(L10n.text(updates.menuTitle)) { updates.check() }.disabled(!updates.canCheck)
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
