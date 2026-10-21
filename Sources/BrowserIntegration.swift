// Sonuvi — GPL-3.0. Browser integration is enabled by the user's Settings action.
import AppKit
import Combine
import CoreFoundation

@MainActor
final class BrowserIntegration: ObservableObject {
    @Published private(set) var enabled = false
    private(set) var connectionToken: String?
    static let extensionURL = URL(string: "https://github.com/davidai1024/Sonuvi/releases/download/v0.4.27/Sonuvi-Browser-Extension.zip")!
    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first! }
    static func manifests(in support: URL) -> [URL] {
        ["Google/Chrome", "Microsoft Edge"].map {
            support.appendingPathComponent($0).appendingPathComponent("NativeMessagingHosts").appendingPathComponent(BrowserProtocol.host + ".json")
        }
    }
    static func manifest(app: URL) -> [String: Any] {
        ["name": BrowserProtocol.host, "description": "Sonuvi selected-text translation and reading",
         "path": app.appendingPathComponent("Contents/MacOS/SonuviBrowserBridge").path,
         "type": "stdio", "allowed_origins": [BrowserProtocol.origin]]
    }
    init() { refresh() }
    func refresh() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SonuviBrowserBridge").path
        let token = BrowserProtocol.token(in: Self.support)
        enabled = token != nil && Self.manifests(in: Self.support).allSatisfy { url in
            guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return value["path"] as? String == helper && value["allowed_origins"] as? [String] == [BrowserProtocol.origin]
        }
        connectionToken = enabled ? token : nil
    }
    static func writeManifests(app: URL, support: URL) throws {
        let file = BrowserProtocol.tokenFile(in: support)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        if BrowserProtocol.token(in: support) == nil {
            let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
            try Data(token.utf8).write(to: file, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let data = try JSONSerialization.data(withJSONObject: manifest(app: app), options: [.prettyPrinted, .sortedKeys])
        for url in manifests(in: support) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    func enable() throws {
        let app = Bundle.main.bundleURL
        guard InstallationPermissionState.isInstalled(app.path),
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/SonuviBrowserBridge").path) else {
            throw TranslateError.message("请先将 Sonuvi 拖入「应用程序」，再启用浏览器连接。")
        }
        try Self.writeManifests(app: app, support: Self.support)
        refresh()
    }
    func disable() throws {
        for url in Self.manifests(in: Self.support) where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["name"] as? String == BrowserProtocol.host,
                  value["allowed_origins"] as? [String] == [BrowserProtocol.origin] else { continue }
            try FileManager.default.removeItem(at: url)
        }
        refresh()
    }

}

@MainActor
final class BrowserMessageServer {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    var receive: ((BrowserRequest) -> BrowserReply)?
    func start() {
        guard port == nil else { return }
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        var shouldFree = DarwinBoolean(false)
        port = CFMessagePortCreateLocal(nil, BrowserProtocol.port as CFString, { _, _, data, info in
            guard let data, let info else { return nil }
            let owner = Unmanaged<BrowserMessageServer>.fromOpaque(info).takeUnretainedValue()
            return MainActor.assumeIsolated {
                let reply: BrowserReply
                do {
                    let request = try BrowserRequest.decode(data as Data)
                    reply = owner.receive?(request) ?? BrowserReply(ok: false, error: "Sonuvi 正在启动，请稍后重试。")
                } catch { reply = BrowserReply(ok: false, error: error.localizedDescription) }
                return Unmanaged.passRetained(reply.data as CFData)
            }
        }, &context, &shouldFree)
        guard let port, let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil; port = nil
    }
}
