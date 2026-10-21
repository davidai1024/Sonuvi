// Sonuvi — GPL-3.0. Selected-text messages only; no shell, files or credentials.
import Foundation

enum BrowserProtocol {
    static let host = "com.wusir.sonuvi.browser"
    static let extensionID = "mgadkmbkjhbofgafpdkdclljmbdlnbac"
    static let origin = "chrome-extension://" + extensionID + "/"
    static let port = "com.wusir.sonuvi.browser.v1"
    static let maximumBytes = 65_536
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
                  text.count <= 6000 else { throw BrowserRequestError.invalid }
        }
        return request
    }
}
enum BrowserRequestError: LocalizedError {
    case invalid
    var errorDescription: String? { "请选择 1–6000 个字符后再使用 Sonuvi。" }
}
struct BrowserReply: Codable {
    let ok: Bool
    let error: String?
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data("{\"ok\":false}".utf8) }
}
