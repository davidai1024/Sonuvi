// Sonuvi — GPL-3.0. Synthetic text only. Never read credentials or browser data.
import AppKit

@MainActor
func runBrowserIntegrationTests() async {
    var count = 0
    func check(_ condition: Bool, _ name: String) {
        guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    for action in [BrowserRequest.Action.translate, .read, .ping] {
        let data = try! JSONEncoder().encode(BrowserRequest(version: 1, action: action, text: action == .ping ? nil : "Synthetic selected text"))
        check((try? BrowserRequest.decode(data))?.action == action, "Allowed browser action decodes: \(action.rawValue)")
    }
    for body in ["{\"version\":1,\"action\":\"delete\",\"text\":\"file\"}", "{\"version\":2,\"action\":\"read\",\"text\":\"x\"}", "{\"version\":1,\"action\":\"read\",\"text\":\" \"}"] {
        check((try? BrowserRequest.decode(Data(body.utf8))) == nil, "Unsupported, empty and version-mismatched browser requests are rejected")
    }
    let longSelection = String(repeating: "中英 mixed selection. ", count: 1800)
    let longData = try! JSONEncoder().encode(BrowserRequest(version: 1, action: .translate, text: longSelection))
    check((try? BrowserRequest.decode(longData))?.text == longSelection, "Long browser selections arrive complete")
    let tooLong = try! JSONEncoder().encode(BrowserRequest(version: 1, action: .translate, text: String(repeating: "a", count: TextLimits.characters + 1)))
    check((try? BrowserRequest.decode(tooLong)) == nil, "Browser cannot bypass the selected-text length limit")
    check((try? BrowserRequest.decode(Data(repeating: 65, count: BrowserProtocol.maximumBytes + 1))) == nil, "Oversized native messages are rejected before decoding")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sonuvi-Browser-Fixture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let support = directory.appendingPathComponent("Library/Application Support")
    do {
        try BrowserIntegration.writeManifests(app: URL(fileURLWithPath: "/Applications/Sonuvi.app"), support: support)
        for url in BrowserIntegration.manifests(in: support) {
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            check(manifest["allowed_origins"] as? [String] == [BrowserProtocol.origin], "Native host permits only Sonuvi's fixed extension ID")
            check(manifest["path"] as? String == "/Applications/Sonuvi.app/Contents/MacOS/SonuviBrowserBridge", "Native host targets the bundled helper without shell commands")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Connection manifest is private to the current user")
        }
    } catch { check(false, "Fixture manifests write successfully") }
    let helper = ProcessInfo.processInfo.environment["SONUVI_BROWSER_FIXTURE_HELPER"].map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SonuviBrowserBridge")
    func invoke(_ request: Data, origin: String = BrowserProtocol.origin, fragmented: Bool = false) async -> BrowserReply? {
        await Task.detached {
            let process = Process(); process.executableURL = helper; process.arguments = [origin]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = directory.path
            process.environment = environment
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            do { try process.run() } catch { return nil }
            if origin == BrowserProtocol.origin {
                var length = UInt32(request.count).littleEndian
                let header = Data(bytes: &length, count: 4)
                if fragmented {
                    input.fileHandleForWriting.write(header.prefix(2)); input.fileHandleForWriting.write(header.suffix(2))
                } else { input.fileHandleForWriting.write(header) }
                input.fileHandleForWriting.write(request)
            }
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard data.count >= 4 else { return nil }
            let length = data.prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            guard length == data.count - 4 else { return nil }
            return try? JSONDecoder().decode(BrowserReply.self, from: data.dropFirst(4))
        }.value
    }
    let rejected = await invoke(Data(), origin: "chrome-extension://untrusted/")
    check(rejected?.ok == false, "Native helper refuses an unrelated extension before opening the app")
    let malformed = await invoke(Data("{\"version\":1,\"action\":\"shell\"}".utf8))
    check(malformed?.ok == false, "Native helper cannot execute arbitrary commands")
    var received: [BrowserRequest] = []
    let server = BrowserMessageServer()
    server.receive = { request in
        guard request.token == BrowserProtocol.token(in: support) else { return BrowserReply(ok: false, error: "Fixture authentication required") }
        received.append(request); return BrowserReply(ok: true, error: nil)
    }
    server.start()
    for action in [BrowserRequest.Action.ping, .translate, .read] {
        let data = try! JSONEncoder().encode(BrowserRequest(version: 1, action: action, text: action == .ping ? nil : "Only this synthetic selection"))
        let result = await invoke(data, fragmented: true)
        check(result?.ok == true && received.last?.action == action, "Real helper and local IPC deliver exactly one request: \(action.rawValue); reply=\(result?.error ?? "none")")
    }
    check(received.count == 3 && received[1].text == "Only this synthetic selection", "Local bridge preserves selection without clipboard, URL or API key access")
    server.stop()
    print("PASS: \(count) browser integration checks")
}
