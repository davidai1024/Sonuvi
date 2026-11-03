// SpeechTrans — GPL-3.0. Network fixtures never leave the process.
import Foundation

final class TranslationFixtureProtocol: URLProtocol {
    static var responseCode = 200
    static var body = ""
    static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: "HTTP/1.1", headerFields: Self.headers.merging(["Content-Type": "text/event-stream"]) { old, _ in old })!
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
    catch TranslateError.outputLimit { count += 1 }
    catch { fatalError("Truncation classification wrong") }
    TranslationFixtureProtocol.body = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"private thought\"}}]}\n\n" + fragment("你好", finish: "stop") + "data: [DONE]\n\n"
    do {
        let output = try await DeepSeekClient.stream(request, configuration: config()) { _ in }
        guard output == "你好" else { fatalError("Reasoning leaked into translation") }; count += 1
    } catch { fatalError("Reasoning fixture failed") }
    TranslationFixtureProtocol.body = fragment("partial") + "data: [DONE]\n\n"
    do { _ = try await DeepSeekClient.stream(request, configuration: config()) { _ in }; fatalError("DONE without stop accepted") }
    catch TranslateError.message { count += 1 }
    catch { fatalError("Missing finish classification wrong") }
    await runTranslationRetryTests()
    print("PASS: \(count) streaming and error-handling fixtures")
}

/// Explicit CLI diagnostic: sends only this fixed synthetic sentence, never user text.
@MainActor
func runTranslationConnectionTest() async -> Int32 {
    do {
        let key = try KeyStore.read()
        let name = UserDefaults.standard.string(forKey: "modelName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = try DeepSeekClient.request(text: "The sun is bright today.", kind: .sentence,
                                               direction: .toChinese, model: name.isEmpty ? "deepseek-flash" : name, key: key)
        let output = try await TranslationRetry.run(onRetry: { print("RETRY: temporary service or connection failure") }, operation: {
            try await DeepSeekClient.stream(request) { _ in }
        })
        guard !output.isEmpty else { return 1 }
        print("PASS: live synthetic translation completed")
        return 0
    } catch let error as TranslateError {
        print("FAIL: " + error.localizedDescription)
    } catch is KeyAccessError {
        print("FAIL: saved key could not be read without user interaction")
    } catch {
        print("FAIL: connection diagnostic did not complete")
    }
    return 1
}
