// Sonuvi — GPL-3.0.
import Foundation
import Darwin

enum PermissionDestination: String { case settings, onboarding }

/// Navigation state only. Never used as evidence that macOS granted access.
struct PermissionReturnState {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var destination: PermissionDestination? {
        guard let value = defaults.string(forKey: "permissions.return.destination"),
              let date = defaults.object(forKey: "permissions.return.date") as? Date,
              Date().timeIntervalSince(date) < 86400 else { return nil }
        return PermissionDestination(rawValue: value)
    }
    var settingsTab: String { defaults.string(forKey: "permissions.return.tab") ?? "权限" }
    func prepare(_ destination: PermissionDestination, settingsTab: String) {
        defaults.set(destination.rawValue, forKey: "permissions.return.destination")
        defaults.set(Date(), forKey: "permissions.return.date")
        defaults.set(settingsTab, forKey: "permissions.return.tab")
        defaults.synchronize()
    }
    func clear() {
        for key in ["permissions.return.destination", "permissions.return.date", "permissions.return.tab"] {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
}

@MainActor
final class RelaunchCoordinator {
    private var process: Process?
    private var session: URL?
    private var generation = UUID()

    func cancel() {
        generation = UUID()
        if let session { try? Data().write(to: session.appendingPathComponent("cancel")) }
        process = nil; session = nil
    }

    /// The app does not quit until the helper has acknowledged readiness.
    func arm(watchingPermission: Bool) async throws {
        cancel()
        let id = generation
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SonuviRelaunch"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw TranslateError.message("未找到重启助手，应用保持打开。请重新安装完整的更新包。")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sonuvi-Relaunch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        session = folder
        let child = Process()
        child.executableURL = helper
        child.arguments = [String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath, folder.path, watchingPermission ? "permission" : "restart"]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        process = child
        do {
            try child.run()
            for _ in 0..<60 {
                guard generation == id else { throw CancellationError() }
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path) { return }
                guard child.isRunning else { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw TranslateError.message("重启助手未就绪，应用保持打开。请稍后重试。")
        } catch {
            if generation == id { cancel() }
            throw error
        }
    }
}

/// One-shot continuation of an explicit repair, never authority to reset TCC.
struct AccessibilityRepairState {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func prepare() {
        defaults.set(Date(), forKey: "permissions.repair.date")
        defaults.synchronize()
    }
    func clear() {
        defaults.removeObject(forKey: "permissions.repair.date")
        defaults.synchronize()
    }
    func consume(now: Date = Date()) -> Bool {
        let date = defaults.object(forKey: "permissions.repair.date") as? Date
        clear()
        guard let date else { return false }
        return (0..<900).contains(now.timeIntervalSince(date))
    }
}

enum AccessibilityRepair {
    static func arguments(bundleID: String?, service: PermissionResetService = .accessibility) throws -> [String] {
        guard bundleID == "com.wusir.musetranslate" else {
            throw TranslateError.message("请从正式的 Sonuvi 应用中修复授权。")
        }
        return ["reset", service.rawValue, "com.wusir.musetranslate"]
    }
    static func reset(bundleID: String?) async throws {
        let args = try arguments(bundleID: bundleID)
        try await run(executable: URL(fileURLWithPath: "/usr/bin/tccutil"), arguments: args)
    }
    // The runner is injectable for tests; tests never invoke tccutil.
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let child = Process()
                child.executableURL = executable; child.arguments = arguments
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                do {
                    try child.run()
                    let deadline = ProcessInfo.processInfo.systemUptime + timeout
                    while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.025)
                    }
                    if child.isRunning {
                        // Kill only the direct child we created, then reap it.
                        kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
                        throw TranslateError.message("修复授权超时，应用保持打开。请稍后重试。")
                    }
                    child.waitUntilExit()
                    guard child.terminationReason == .exit && child.terminationStatus == 0 else {
                        throw TranslateError.message("系统未能重置 Sonuvi 的权限记录。请在系统设置中移除 Sonuvi 后重新添加。")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// Only these two services, always scoped to this app's stable bundle identifier.
enum PermissionResetService: String, CaseIterable {
    case accessibility = "Accessibility", screenCapture = "ScreenCapture"
    var title: String { self == .accessibility ? "辅助功能" : "屏幕录制" }
}
struct PermissionResetReport {
    var cleared: [PermissionResetService] = []
    var failed: [PermissionResetService] = []
    var message: String {
        if failed.isEmpty { return "旧权限记录已清理，请重新开启辅助功能和屏幕录制。" }
        return L10n.text("未能清理以下权限，请在系统设置中移除 Sonuvi 后重新添加：") + failed.map { L10n.text($0.title) }.joined(separator: "、")
    }
}
extension AccessibilityRepair {
    static func resetBoth(bundleID: String?, execute: ([String]) async throws -> Void = { args in
        try await run(executable: URL(fileURLWithPath: "/usr/bin/tccutil"), arguments: args)
    }) async throws -> PermissionResetReport {
        // Validate the entire plan before the first mutation.
        let commands = try PermissionResetService.allCases.map { ($0, try arguments(bundleID: bundleID, service: $0)) }
        var report = PermissionResetReport()
        for (service, args) in commands {
            do { try await execute(args); report.cleared.append(service) }
            catch { report.failed.append(service) }
        }
        return report
    }
}

/// Detect a new installed copy, including same-version Finder replacements.
/// Persist before attempting repair: failed/partial repairs never cause a loop.
struct InstallationPermissionState {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func isInstalled(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }
    static func fingerprint(bundle: Bundle = .main) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: bundle.bundlePath)) ?? [:]
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let device = (attrs[.systemNumber] as? NSNumber)?.stringValue ?? "unknown"
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.stringValue ?? "unknown"
        let created = (attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(build):\(device):\(inode):\(created)"
    }
    func shouldRepair(fingerprint: String, installed: Bool, returningUser: Bool, accessibility: Bool, screen: Bool, resumingRepair: Bool = false, preserveExistingAuthorization: Bool = false) -> Bool {
        guard installed else { return false }
        let previous = defaults.string(forKey: "permissions.install.fingerprint")
        defaults.set(fingerprint, forKey: "permissions.install.fingerprint")
        defaults.synchronize()
        // Stable-signed upgrades must not clear another permission merely because
        // a user declined one, or TCC has not refreshed yet. Repair stays explicit.
        guard !preserveExistingAuthorization else { return false }
        return !resumingRepair && previous != fingerprint && (previous != nil || returningUser) && (!accessibility || !screen)
    }
}

enum StartupDestination: Equatable {
    case onboarding, permissions, models, settings
    static func resolve(onboardingComplete: Bool, accessibility: Bool, screen: Bool, keyAccessNeedsAttention: Bool = false) -> Self {
        if !onboardingComplete { return .onboarding }
        if !accessibility || !screen { return .permissions }
        return keyAccessNeedsAttention ? .models : .settings
    }
}

/// Keep windows hidden until installation checks finish. The old process never
/// presents a window just before the repair helper replaces it.
struct StartupPresentationGate {
    private enum Phase { case preparing, ready, relaunching }
    private var phase = Phase.preparing
    var canPresent: Bool { phase == .ready }
    mutating func finishPreparation() {
        if phase == .preparing { phase = .ready }
    }
    mutating func beginRelaunch() { phase = .relaunching }
}
