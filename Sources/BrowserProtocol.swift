// Sonuvi — GPL-3.0. Selected-text messages only; no shell, files or credentials.
import Foundation

enum BrowserProtocol {
    static let host = "com.wusir.sonuvi.browser"
    static let extensionID = "mgadkmbkjhbofgafpdkdclljmbdlnbac"
    static let origin = "chrome-extension://" + extensionID + "/"
    static let productionPort = "com.wusir.sonuvi.browser.v1"
    static var port: String {
        #if SONUVI_BROWSER_FIXTURE
        return ProcessInfo.processInfo.environment["SONUVI_BROWSER_FIXTURE_PORT"] ?? productionPort
        #else
        // Test processes get an isolated local port; the shipped helper always
        // uses productionPort. No user setting changes the production channel.
        if CommandLine.arguments.contains("--browser-test"), let fixture = ProcessInfo.processInfo.environment["SONUVI_BROWSER_FIXTURE_PORT"] { return fixture }
        return productionPort
        #endif
    }
    static let maximumBytes = TextLimits.messageBytes
    static func tokenFile(in support: URL) -> URL {
        support.appendingPathComponent("MuseTranslate/Browser/connection.token")
    }
    static func token(in support: URL) -> String? {
        guard let value = try? String(contentsOf: tokenFile(in: support), encoding: .utf8), value.count == 64 else { return nil }
        return value
    }
}
struct BrowserRequest: Codable {
    enum Action: String, Codable { case ping, translate, read }
    let version: Int
    let action: Action
    let text: String?
    var token: String? = nil
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= BrowserProtocol.maximumBytes else { throw BrowserRequestError.invalid }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.version == 1 else { throw BrowserRequestError.invalid }
        if request.action != .ping {
            guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= TextLimits.characters else { throw BrowserRequestError.invalid }
        }
        return request
    }
}
enum BrowserRequestError: LocalizedError {
    case invalid
    var errorDescription: String? { "请选择 1–20 万个字符后再使用 Sonuvi。" }
}
struct BrowserReply: Codable {
    let ok: Bool
    let error: String?
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data("{\"ok\":false}".utf8) }
}
