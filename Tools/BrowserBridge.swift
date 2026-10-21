// Sonuvi — GPL-3.0. Chrome native-messaging bridge; selected text stays in local IPC.
import AppKit
import CoreFoundation

func reply(_ value: BrowserReply) -> Never {
    let body = value.data
    var length = UInt32(body.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
    FileHandle.standardOutput.write(body)
    exit(0)
}
func readExactly(_ count: Int) -> Data? {
    var result = Data()
    while result.count < count {
        guard let part = try? FileHandle.standardInput.read(upToCount: count - result.count), !part.isEmpty else { return nil }
        result.append(part)
    }
    return result
}
@main
struct BrowserBridgeMain {
    static func main() {
        guard CommandLine.arguments.dropFirst().first == BrowserProtocol.origin,
              let header = readExactly(4) else { reply(BrowserReply(ok: false, error: "浏览器连接无效。")) }
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= BrowserProtocol.maximumBytes, let payload = readExactly(Int(length)),
              var request = try? BrowserRequest.decode(payload) else { reply(BrowserReply(ok: false, error: "请选择 1–6000 个字符后再使用 Sonuvi。")) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        guard let token = BrowserProtocol.token(in: support) else { reply(BrowserReply(ok: false, error: "请先在 Sonuvi 设置中启用浏览器连接。")) }
        request.token = token
        guard let authenticatedPayload = try? JSONEncoder().encode(request) else { reply(BrowserReply(ok: false, error: "浏览器连接无效。")) }
        let app = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == "com.wusir.musetranslate" else { reply(BrowserReply(ok: false, error: "请重新安装 Sonuvi。")) }
        let deadline = Date().addingTimeInterval(12)
        var opening = false
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.15)
        timer.setEventHandler {
            if let remote = CFMessagePortCreateRemote(nil, BrowserProtocol.port as CFString) {
                var response: Unmanaged<CFData>?
                let status = CFMessagePortSendRequest(remote, 1, authenticatedPayload as CFData, 1, 3, CFRunLoopMode.defaultMode.rawValue, &response)
                guard status == kCFMessagePortSuccess, let data = response?.takeRetainedValue(),
                      let result = try? JSONDecoder().decode(BrowserReply.self, from: data as Data) else { reply(BrowserReply(ok: false, error: "Sonuvi 暂时未响应，请重新打开后重试。")) }
                reply(result)
            }
            guard Date() < deadline else { reply(BrowserReply(ok: false, error: "请先打开 Sonuvi，再重试。")) }
            if !opening {
                opening = true
                let config = NSWorkspace.OpenConfiguration(); config.activates = false; config.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                    if error != nil { reply(BrowserReply(ok: false, error: "无法打开 Sonuvi，请先将应用移入「应用程序」。")) }
                }
            }
        }
        timer.resume()
        dispatchMain()
    }
}
