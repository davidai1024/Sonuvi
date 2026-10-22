// Isolated Sparkle integration fixture. Auto choices apply only to this synthetic app.
import AppKit
import Sparkle

let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "FixtureRoot") as! String)
func event(_ name: String, _ details: [String: Any] = [:]) {
    var value = details
    value["event"] = name
    value["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    let url = root.appendingPathComponent("events.jsonl")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    if let file = try? FileHandle(forWritingTo: url) {
        defer { try? file.close() }
        _ = try? file.seekToEnd(); try? file.write(contentsOf: data + Data([10]))
    }
}

@MainActor final class Fixture: NSObject, NSApplicationDelegate, SPUUserDriver {
    var updater: SPUUpdater!
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            event("relaunched", ["model_preserved": (try? String(contentsOf: root.appendingPathComponent("Voice/model-marker"))) == "synthetic-local-model"])
            NSApp.terminate(nil); return
        }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do { try updater.start(); updater.checkForUpdates() }
        catch { event("start_error", ["error": error.localizedDescription]); NSApp.terminate(nil) }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { event("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        event("found", ["target": appcastItem.versionString]); reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        event("no_update"); acknowledgement(); NSApp.terminate(nil)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let e = error as NSError
        event("rejected", ["domain": e.domain, "code": e.code, "error": e.localizedDescription]); acknowledgement(); NSApp.terminate(nil)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { event("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { event("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { event("ready"); reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { event("installing") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let fixture = Fixture()
    app.delegate = fixture
    app.setActivationPolicy(.accessory)
    app.run()
}
