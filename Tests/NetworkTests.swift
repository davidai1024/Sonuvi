// SpeechTrans — GPL-3.0. Network fixtures never leave the process.
import Foundation

final class TranslationFixtureProtocol: URLProtocol {
    static var responseCode = 200
    static var body = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func runNetworkTests() async {
    var count = 0
    func config() -> URLSessionConfiguration { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TranslationFixtureProtocol.self]; return config }
    let request = try! DeepSeekClient.request(text: "Hello.", kind: .sentence, direction: .toChinese, model: "deepseek-flash", key: "fixture-key")
    func fragment(_ text: String, finish: String? = nil) -> String {
        let choice: [String: Any] = ["delta": ["content": text], "finish_reason": finish as Any? ?? NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return "data: " + String(data: data, encoding: .utf8)! + "\n\n"
    }
    TranslationFixtureProtocol.body = fragment("你") + fragment("好", finish: "stop") + "data: [DONE]\n\n"
    do {
        let output = try await DeepSeekClient.stream(request, configuration: config()) { _ in }
        guard output == "你好" else { fatalError("Streaming result mismatch") }
        count += 1
    } catch { fatalError("Streaming fixture failed: \(error)") }
    TranslationFixtureProtocol.responseCode = 401
    do { _ = try await DeepSeekClient.stream(request, configuration: config()) { _ in }; fatalError("401 accepted") }
    catch TranslateError.message { count += 1 }
    catch { fatalError("401 classification wrong") }
    TranslationFixtureProtocol.responseCode = 429
    do { _ = try await DeepSeekClient.stream(request, configuration: config()) { _ in }; fatalError("429 accepted") }
    catch TranslateError.retryable { count += 1 }
    catch { fatalError("429 classification wrong") }
    TranslationFixtureProtocol.responseCode = 503
    do { _ = try await DeepSeekClient.stream(request, configuration: config()) { _ in }; fatalError("503 accepted") }
    catch TranslateError.retryable { count += 1 }
    catch { fatalError("503 classification wrong") }
    TranslationFixtureProtocol.responseCode = 200
    TranslationFixtureProtocol.body = fragment("partial")
    do { _ = try await DeepSeekClient.stream(request, configuration: config()) { _ in }; fatalError("Incomplete stream accepted") }
    catch TranslateError.message { count += 1 }
    catch { fatalError("Incomplete stream classification wrong") }
    TranslationFixtureProtocol.body = fragment("truncated", finish: "length") + "data: [DONE]\n\n"
    do { _ = try await DeepSeekClient.stream(request, configuration: config()) { _ in }; fatalError("Truncation accepted") }
    catch TranslateError.message { count += 1 }
    catch { fatalError("Truncation classification wrong") }
    print("PASS: \(count) streaming and error-handling fixtures")
}
