// Sonuvi — GPL-3.0.
import Foundation

@MainActor
func runPermissionTests() async {
    var count = 0
    func check(_ condition: Bool, _ name: String) {
        guard condition else { print("FAIL: \(name)"); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    var gate = StartupPresentationGate()
    check(!gate.canPresent, "Initial activation and reopen cannot flash a window before installation checks")
    gate.beginRelaunch()
    check(!gate.canPresent, "Automatic repair keeps the retiring process invisible")
    gate.finishPreparation()
    check(!gate.canPresent, "Delayed activation cannot reopen a window while relaunching")
    var resumed = StartupPresentationGate()
    resumed.finishPreparation()
    check(resumed.canPresent, "Relaunched process presents the final permission destination")
    var failed = StartupPresentationGate()
    failed.finishPreparation()
    check(failed.canPresent, "Failed preparation unlocks the permission page instead of leaving a hidden app")
    let suite = "SonuviRepairTest-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = AccessibilityRepairState(defaults: defaults)
    check(!state.consume(), "Ordinary launch never requests repair")
    state.prepare()
    check(AccessibilityRepairState(defaults: defaults).consume(), "Explicit repair resumes across process boundaries")
    check(!state.consume(), "Repair continuation is consumed exactly once")
    state.prepare(); state.clear()
    check(!state.consume(), "Failed repair leaves no pending authorization prompt")
    defaults.set(Date(timeIntervalSinceNow: -901), forKey: "permissions.repair.date")
    check(!state.consume(), "Expired repair never triggers a later prompt")
    defaults.set(Date(timeIntervalSinceNow: 100), forKey: "permissions.repair.date")
    check(!state.consume(), "Invalid future repair timestamp rejected")
    do {
        let args = try AccessibilityRepair.arguments(bundleID: "com.wusir.musetranslate")
        check(args == ["reset", "Accessibility", "com.wusir.musetranslate"], "Reset scoped to Sonuvi Accessibility only")
    } catch { check(false, "Expected app can construct repair") }
    for id: String? in [nil, "", "com.apple.finder", "com.wusir.musetranslate.preview"] {
        do { _ = try AccessibilityRepair.arguments(bundleID: id); check(false, "Wrong bundle rejected") }
        catch { check(true, "Missing, foreign and preview bundles cannot reset permissions") }
    }
    let origin = PermissionReturnState(defaults: defaults)
    origin.prepare(.settings, settingsTab: "通用"); state.prepare(); _ = state.consume()
    check(origin.destination == .settings && origin.settingsTab == "通用", "Repair continuation preserves Settings return")
    origin.prepare(.onboarding, settingsTab: "通用"); state.prepare(); _ = state.consume()
    check(origin.destination == .onboarding, "Repair continuation preserves onboarding return")
    // Harmless subprocesses only. Never reset real macOS permission during tests.
    do {
        try await AccessibilityRepair.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        check(true, "Successful subprocess completes repair stage")
    } catch { check(false, "Successful subprocess") }
    do {
        try await AccessibilityRepair.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        check(false, "Nonzero status must fail")
    } catch { check(true, "Nonzero status surfaces failure instead of restarting") }
    do {
        try await AccessibilityRepair.run(executable: URL(fileURLWithPath: "/nonexistent-sonuvi-test"), arguments: [])
        check(false, "Missing executable must fail")
    } catch { check(true, "Process launch failure is returned") }
    var heartbeat = false
    let beat = Task { @MainActor in try? await Task.sleep(nanoseconds: 25_000_000); heartbeat = true }
    let start = ProcessInfo.processInfo.systemUptime
    do {
        try await AccessibilityRepair.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.15)
        check(false, "Timeout must fail")
    } catch { check(true, "Stalled subprocess is terminated") }
    check(heartbeat, "Repair process does not block UI executor")
    await beat.value
    check(ProcessInfo.processInfo.systemUptime - start < 3, "Timeout returns promptly")
    let installation = InstallationPermissionState(defaults: defaults)
    check(!installation.shouldRepair(fingerprint: "first", installed: true, returningUser: false, accessibility: false, screen: false), "Fresh installs keep onboarding and do not reset permissions")
    check(!installation.shouldRepair(fingerprint: "first", installed: true, returningUser: true, accessibility: false, screen: false), "An ordinary restart never clears pending authorizations")
    check(installation.shouldRepair(fingerprint: "updated", installed: true, returningUser: true, accessibility: true, screen: false), "Updated copy with one missing permission triggers paired repair")
    check(!installation.shouldRepair(fingerprint: "updated", installed: true, returningUser: true, accessibility: false, screen: false), "Failed or partial auto-repair does not repeat on next launch")
    check(!installation.shouldRepair(fingerprint: "signed-update", installed: true, returningUser: true, accessibility: true, screen: true), "Valid permissions survive updates untouched")
    check(!installation.shouldRepair(fingerprint: "resuming", installed: true, returningUser: true, accessibility: false, screen: false, resumingRepair: true), "Repair relaunch records the install without resetting again")
    check(!installation.shouldRepair(fingerprint: "dmg", installed: false, returningUser: true, accessibility: false, screen: false), "Running from DMG never resets installed app permissions")
    check(defaults.string(forKey: "permissions.install.fingerprint") == "resuming", "DMG launch does not change installed-copy marker")
    defaults.removeObject(forKey: "permissions.install.fingerprint")
    check(installation.shouldRepair(fingerprint: "migration", installed: true, returningUser: true, accessibility: false, screen: true), "Older versions without a marker migrate once when permission is missing")
    check(!installation.shouldRepair(fingerprint: "fixed-signing-migration", installed: true, returningUser: true, accessibility: false, screen: true, preserveExistingAuthorization: true), "Fixed signing migration never clears a valid Screen Recording permission")
    check(!installation.shouldRepair(fingerprint: "sparkle-update", installed: true, returningUser: true, accessibility: true, screen: false, preserveExistingAuthorization: true), "Sparkle upgrade preserves Accessibility when Screen Recording was declined")
    let migration = SigningPermissionMigration(defaults: defaults)
    defaults.set(true, forKey: "accessibilityPermissionRequested")
    defaults.set(true, forKey: "screenPermissionRequested")
    check(migration.observe(identity: "fixed-certificate", installed: true, returningUser: true, accessibility: false, screen: true), "An old installation without a signing marker gets a migration recovery hint")
    check(!defaults.bool(forKey: "accessibilityPermissionRequested") && defaults.bool(forKey: "screenPermissionRequested"), "Migration clears only the obsolete request flag, keeping a valid permission untouched")
    check(migration.observe(identity: "fixed-certificate", installed: true, returningUser: true, accessibility: false, screen: true), "Unresolved migration survives a relaunch")
    migration.resolve()
    defaults.set(true, forKey: "accessibilityPermissionRequested")
    check(!migration.observe(identity: "fixed-certificate", installed: true, returningUser: true, accessibility: false, screen: true), "A normal same-certificate update never reopens a dismissed migration")
    check(defaults.bool(forKey: "accessibilityPermissionRequested"), "Same-certificate updates retain request state when permission was declined")
    check(migration.observe(identity: "another-certificate", installed: true, returningUser: true, accessibility: false, screen: true), "A genuinely changed certificate can need a new migration hint")
    check(!migration.observe(identity: "another-certificate", installed: true, returningUser: true, accessibility: true, screen: true), "Real system grants resolve the migration hint")
    check(!migration.observe(identity: "uninstalled-preview", installed: false, returningUser: true, accessibility: false, screen: false) && defaults.string(forKey: "permissions.signing.identity") == "another-certificate", "DMG and preview copies do not replace the installed signing marker")
    defaults.removeObject(forKey: "permissions.signing.identity")
    check(!migration.observe(identity: "fresh-fixed", installed: true, returningUser: false, accessibility: false, screen: false), "A fresh fixed-signed install has ordinary onboarding, not a stale-record warning")
    check(SigningPermissionMigration.unavailable(accessibility: true, screen: false) == [.screenCapture], "Selective repair excludes valid Accessibility authorization")
    check(SigningPermissionMigration.unavailable(accessibility: false, screen: true) == [.accessibility], "Selective repair excludes valid Screen Recording authorization")
    if Bundle.main.object(forInfoDictionaryKey: "SonuviFixedSigning") as? Bool == true {
        check(SigningPermissionMigration.currentIdentity?.count == 64, "Migration identity comes from the running app's actual signing certificate")
    }
    var selectiveCommands: [[String]] = []
    do {
        let selective = try await AccessibilityRepair.resetServices(bundleID: "com.wusir.musetranslate", services: [.screenCapture, .screenCapture], execute: { selectiveCommands.append($0) })
        check(selectiveCommands == [["reset", "ScreenCapture", "com.wusir.musetranslate"]] && selective.cleared == [.screenCapture], "An explicit selective repair deduplicates and touches only the unavailable service")
    } catch { check(false, "Selective repair succeeds") }
    check(InstallationPermissionState.isInstalled("/Applications/Sonuvi.app") && !InstallationPermissionState.isInstalled("/Volumes/Sonuvi/Sonuvi.app"), "Installed copies distinguished from mounted disk image")
    check(StartupDestination.resolve(onboardingComplete: false, accessibility: false, screen: false) == .onboarding, "First launch retains onboarding")
    check(StartupDestination.resolve(onboardingComplete: true, accessibility: false, screen: true) == .permissions, "Missing Accessibility opens Permissions")
    check(StartupDestination.resolve(onboardingComplete: true, accessibility: true, screen: false) == .permissions, "Missing Screen Recording opens Permissions")
    check(StartupDestination.resolve(onboardingComplete: true, accessibility: true, screen: true) == .settings, "Ordinary startup opens Settings, not an empty translation")
    check(StartupDestination.resolve(onboardingComplete: true, accessibility: true, screen: true, keyAccessNeedsAttention: true) == .models, "Reinstalled app presents API authorization before first translation")
    check(StartupDestination.resolve(onboardingComplete: true, accessibility: false, screen: true, keyAccessNeedsAttention: true) == .permissions, "System permissions retain priority while API notice is shown across settings")
    check(StartupDestination.resolve(onboardingComplete: false, accessibility: true, screen: true, keyAccessNeedsAttention: true) == .onboarding, "Keychain notice does not skip first-run onboarding")
    let credentials = AppModel()
    var interactions: [Bool] = []
    credentials.refreshAPIKeyAccess { interactive in
        interactions.append(interactive); throw KeyAccessError.authorizationRequired
    }
    check(credentials.hasKey && credentials.keyAccessRequired && interactions == [false], "Startup detects retained but inaccessible key without requesting password")
    do {
        try credentials.authorizeAPIKeyAccess { interactive in
            interactions.append(interactive); throw KeyAccessError.authorizationRequired
        }
        check(false, "Cancelled access must not succeed")
    } catch { check(credentials.keyAccessRequired && credentials.hasKey, "Denied authorization preserves saved key and recovery notice") }
    do {
        try credentials.authorizeAPIKeyAccess { interactive in interactions.append(interactive); return "synthetic-test-value" }
        check(credentials.hasKey && !credentials.keyAccessRequired && interactions == [false, true, true], "Only explicit Allow Access requests interaction and clears notice on success")
    } catch { check(false, "Explicit credential authorization succeeds") }
    credentials.refreshAPIKeyAccess { _ in throw KeyAccessError.unavailable(-25291) }
    check(credentials.hasKey && !credentials.keyAccessIssue.isEmpty, "Temporary keychain failure is visible and never erases configured status")
    credentials.refreshAPIKeyAccess { _ in throw KeyAccessError.missing }
    check(!credentials.hasKey && !credentials.keyAccessRequired && credentials.keyAccessIssue.isEmpty, "Fresh installs without API key do not get a reauthorization warning")
    credentials.previewMode = true
    credentials.refreshAPIKeyAccess { _ in check(false, "Preview must not inspect the real keychain"); return "" }
    check(!credentials.hasKey, "Appearance preview leaves credentials untouched")
    var commands: [[String]] = []
    do {
        let report = try await AccessibilityRepair.resetBoth(bundleID: "com.wusir.musetranslate", execute: { commands.append($0) })
        check(commands == [["reset", "Accessibility", "com.wusir.musetranslate"], ["reset", "ScreenCapture", "com.wusir.musetranslate"]], "Both resets are precisely scoped to Sonuvi")
        check(report.cleared.count == 2 && report.failed.isEmpty, "Paired success reports both permissions cleared")
        commands = []
        let partial = try await AccessibilityRepair.resetBoth(bundleID: "com.wusir.musetranslate", execute: { args in
            commands.append(args)
            if args[1] == "Accessibility" { throw NSError(domain: "fixture", code: 1) }
        })
        check(commands.count == 2 && partial.cleared == [.screenCapture] && partial.failed == [.accessibility], "First failure still attempts the second service and reports partial result")
        let failed = try await AccessibilityRepair.resetBoth(bundleID: "com.wusir.musetranslate", execute: { _ in throw NSError(domain: "fixture", code: 1) })
        check(failed.cleared.isEmpty && failed.failed.count == 2, "Total failure never claims permission records cleared")
    } catch { check(false, "Expected bundle supports both reset services") }
    commands = []
    do {
        _ = try await AccessibilityRepair.resetBoth(bundleID: "com.apple.finder", execute: { commands.append($0) })
        check(false, "Foreign bundle reset must fail")
    } catch { check(commands.isEmpty, "Foreign bundle rejected before either command runs") }
    print("PASS: \(count) permission repair checks")
}
