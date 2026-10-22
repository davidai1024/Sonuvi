// Isolated, user-approved TCC upgrade experiment. Never edits the TCC database.
import AppKit
import ApplicationServices
import ScreenCaptureKit

let testRoot = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "SonuviTestRoot") as! String)
let expectedTitle = "Sonuvi synthetic accessibility target"

func save(_ value: [String: Any], _ name: String) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: testRoot.appendingPathComponent(name), options: .atomic)
    }
}

#if TARGET_APP
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main!.frame
        let rect = NSRect(x: screen.maxX - 440, y: screen.midY - 110, width: 420, height: 220)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = expectedTitle
        window.contentView!.wantsLayer = true
        window.contentView!.layer!.backgroundColor = NSColor.systemTeal.cgColor
        let label = NSTextField(wrappingLabelWithString: "Sonuvi 权限验证靶标\n\n这里只包含固定测试内容。\n测试结束后会自动关闭。")
        label.frame = NSRect(x: 30, y: 45, width: 360, height: 125)
        label.font = .systemFont(ofSize: 17)
        window.contentView!.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        save(["pid": ProcessInfo.processInfo.processIdentifier, "x": rect.midX,
              "y": NSScreen.screens.first!.frame.maxY - rect.midY], "target.json")
    }
}
#else
#if SECOND_VERSION
let revision = 2
#else
let revision = 1
#endif

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var axLabel = NSTextField(labelWithString: "")
    var screenLabel = NSTextField(labelWithString: "")
    var detail = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?
    var axSuccess = false
    var captureSuccess = false
    var axError = ""
    var captureError = ""
    var probing = false
    var lastAttempt = Date.distantPast
    var permissionRequests = 0
    var screenRequests = 0
    var requestingCapture = false
    var authorizationError = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main!.frame
        window = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.midY - 190, width: 530, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sonuvi 权限验证 · V\(revision)"
        let title = NSTextField(labelWithString: revision == 1 ? "首次授权，建立验证基线" : "同证书新版，验证授权是否保留")
        title.font = .boldSystemFont(ofSize: 21)
        title.frame = NSRect(x: 28, y: 318, width: 485, height: 30)
        window.contentView!.addSubview(title)
        let explanation = NSTextField(wrappingLabelWithString: "这是独立测试 App，不会修改正式 Sonuvi。\n仅读取右侧测试窗口标题，并截取测试区域的 1 个像素；不保存图片。")
        explanation.frame = NSRect(x: 28, y: 246, width: 475, height: 58)
        window.contentView!.addSubview(explanation)
        axLabel.frame = NSRect(x: 28, y: 205, width: 475, height: 24)
        screenLabel.frame = NSRect(x: 28, y: 168, width: 475, height: 24)
        window.contentView!.addSubview(axLabel)
        window.contentView!.addSubview(screenLabel)
        if revision == 1 {
            button("开启辅助功能", #selector(requestAX), x: 28, y: 113, width: 145)
            button("开启屏幕录制", #selector(requestCapture), x: 185, y: 113, width: 145)
            button("重新检测", #selector(retry), x: 342, y: 113, width: 140)
            button("列表找不到？显示测试 App", #selector(revealApp), x: 28, y: 73, width: 230)
        } else {
            button("重新检测（不请求授权）", #selector(retry), x: 28, y: 113, width: 230)
        }
        detail.frame = NSRect(x: 28, y: 12, width: 475, height: 56)
        detail.textColor = .secondaryLabelColor
        window.contentView!.addSubview(detail)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.probe() }
        }
        Task { await probe() }
    }

    func button(_ title: String, _ action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: x, y: y, width: width, height: 34)
        window.contentView!.addSubview(button)
    }
    @objc func requestAX() {
        guard revision == 1 else { return }
        permissionRequests += 1
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func requestCapture() {
        guard revision == 1, !requestingCapture else { return }
        permissionRequests += 1
        screenRequests += 1
        requestingCapture = true
        save(["phase": "ScreenCaptureKit_request_started", "request": screenRequests], "capture-request.json")
        Task { @MainActor in
            do {
                // Trigger the framework's consent flow, like Apple's capture sample.
                // Discard the metadata immediately; never inspect or record window names.
                _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                authorizationError = ""
            } catch {
                let error = error as NSError
                authorizationError = "\(error.domain):\(error.code)"
            }
            requestingCapture = false
            lastAttempt = .distantPast
            save(["phase": "ScreenCaptureKit_request_returned", "request": screenRequests,
                  "preflight": CGPreflightScreenCaptureAccess(), "error": authorizationError], "capture-request.json")
            await probe()
            if !CGPreflightScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
    }
    @objc func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    @objc func retry() {
        axSuccess = false; captureSuccess = false; lastAttempt = .distantPast
        Task { await probe() }
    }
    func probe() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        let axGranted = AXIsProcessTrusted()
        let screenGranted = CGPreflightScreenCaptureAccess()
        if Date().timeIntervalSince(lastAttempt) >= 10 {
            lastAttempt = Date()
            if let data = try? Data(contentsOf: testRoot.appendingPathComponent("target.json")),
               let target = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = target["pid"] as? Int32 {
                if axGranted && !axSuccess {
                    let app = AXUIElementCreateApplication(pid)
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                    if status == .success, let windows = value as? [AXUIElement] {
                        for item in windows {
                            var title: CFTypeRef?
                            let result = AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
                            if result == .success && title as? String == expectedTitle { axSuccess = true }
                        }
                    }
                    axError = axSuccess ? "" : "AXError=\(status.rawValue); synthetic title match failed"
                }
                if screenGranted && !captureSuccess, let x = target["x"] as? Double, let y = target["y"] as? Double {
                    do {
                        // Same capture API as Sonuvi. Nothing is encoded, written or uploaded.
                        let image = try await SCScreenshotManager.captureImage(in: CGRect(x: x, y: y, width: 1, height: 1))
                        captureSuccess = image.width > 0 && image.height > 0
                        captureError = ""
                    } catch {
                        let error = error as NSError
                        captureError = "\(error.domain):\(error.code)"
                    }
                }
            }
        }
        axLabel.stringValue = "辅助功能：\(axGranted ? "已授权" : "待授权") · 实际读取\(axSuccess ? "成功 ✓" : "未通过")"
        screenLabel.stringValue = "屏幕录制：\(screenGranted ? "已授权" : "待授权") · 实际截图\(captureSuccess ? "成功 ✓" : "未通过")"
        let passed = axGranted && screenGranted && axSuccess && captureSuccess
        detail.stringValue = passed
            ? (revision == 1 ? "基线通过。接下来会自动替换为同证书的 V2，检查升级后权限。" : "升级验证通过：两项权限保留，实际功能成功。V2 没有调用授权请求。")
            : (revision == 1 ? "权限列表找不到时，点上方「显示测试 App」，再点系统权限列表的 ＋ 添加它。若提示重新打开，请按系统提示操作。" : "新版不会请求授权；当前状态已记录，等待排查。")
        save(["revision": revision, "pid": ProcessInfo.processInfo.processIdentifier,
              "timestamp": ISO8601DateFormatter().string(from: Date()),
              "accessibility_granted": axGranted, "screen_recording_granted": screenGranted,
              "accessibility_read_succeeded": axSuccess, "screen_capture_succeeded": captureSuccess,
              "accessibility_error": axError, "screen_capture_error": captureError,
              "permission_request_calls": permissionRequests, "screen_permission_request_calls": screenRequests,
              "authorization_error": authorizationError, "passed": passed], "v\(revision)-status.json")
    }
}
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
