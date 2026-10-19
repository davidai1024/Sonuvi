// Sonuvi — GPL-3.0. A bounded helper, armed only by an explicit permission/restart action.
import AppKit
import Darwin

guard CommandLine.arguments.count == 5,
      let parent = Int32(CommandLine.arguments[1]), parent > 1 else { exit(1) }
let app = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
let session = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
let mode = CommandLine.arguments[4]
guard ["permission", "restart"].contains(mode),
      app.pathExtension == "app",
      FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Sonuvi").path),
      FileManager.default.fileExists(atPath: session.path) else { exit(2) }
// Detach from the launching process's session; do not inherit its terminal.
_ = setsid()
let parentApp = NSRunningApplication(processIdentifier: parent)
let deadline = Date().addingTimeInterval(mode == "permission" ? 900 : 45)
func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: session)
    exit(code)
}
let timer = DispatchSource.makeTimerSource(queue: .main)
var opening = false
func isRunning() -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: app)?.bundleIdentifier ?? "com.wusir.musetranslate")
        .contains { $0.processIdentifier != parent && !$0.isTerminated }
}
func reopen(attempt: Int = 0) {
    // System Settings may already have reopened the app. Never launch a duplicate.
    if isRunning() { finish(0) }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true; config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: app, configuration: config) { running, error in
        if error == nil, running != nil { finish(0) }
        if attempt < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reopen(attempt: attempt + 1) }
        } else { finish(4) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(isRunning() ? 0 : 5) }
}
timer.schedule(deadline: .now(), repeating: .milliseconds(100))
timer.setEventHandler {
    if FileManager.default.fileExists(atPath: session.appendingPathComponent("cancel").path) { finish(0) }
    if Date() > deadline { finish(3) }
    guard !opening else { return }
    let gone = parentApp?.isTerminated == true || (kill(parent, 0) != 0 && errno == ESRCH)
    if gone {
        opening = true; timer.cancel()
        // Give LaunchServices time to unregister the old process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reopen() }
    }
}
timer.resume()
do { try Data("ready".utf8).write(to: session.appendingPathComponent("ready"), options: .atomic) }
catch { finish(6) }
// NSWorkspace completion runs on dispatch's main queue. RunLoop.run can
// return immediately in a command-line helper with no installed run-loop source.
dispatchMain()
