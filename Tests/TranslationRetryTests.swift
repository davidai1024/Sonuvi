// Sonuvi — GPL-3.0. Synthetic recovery fixtures, no real network or credentials.
import Foundation

@MainActor
func runTranslationRetryTests() async {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
        guard value else { fatalError("FAIL: " + message) }; checks += 1
    }
    var calls = 0; var waits: [TimeInterval] = []; var notices = 0
    let result = try! await TranslationRetry.run(sleep: { waits.append($0) }, onRetry: { notices += 1 }, operation: {
        calls += 1
        if calls < 5 { throw TranslateError.retryable("busy") }
        return "complete"
    })
    check(result == "complete" && calls == 5 && waits == [2, 4, 8, 16] && notices == 4,
          "Service recovers after several failures with exponential backoff")
    calls = 0; waits = []
    do {
        _ = try await TranslationRetry.run(sleep: { waits.append($0) }, onRetry: {}, operation: {
            calls += 1; throw TranslateError.retryable("service unavailable")
        })
        fatalError("Unbounded failure accepted")
    } catch { check(calls == 5 && waits.count == 4 && error.localizedDescription == "service unavailable", "Persistent failure stops with its actionable message") }
    calls = 0; waits = []
    do {
        _ = try await TranslationRetry.run(sleep: { waits.append($0) }, onRetry: {}, operation: {
            calls += 1; throw TranslateError.message("invalid key")
        })
        fatalError("Authentication failure accepted")
    } catch { check(calls == 1 && waits.isEmpty, "Permanent errors never retry") }
    calls = 0; waits = []
    _ = try! await TranslationRetry.run(sleep: { waits.append($0) }, onRetry: {}, operation: {
        calls += 1
        if calls == 1 { throw TranslateError.retryable("busy", retryAfter: 12) }
        return "ready"
    })
    check(waits == [12], "Server wait hint is honored")
    for (raw, expected) in [("15", 15.0), ("999", 60.0), ("-1", -1.0), ("NaN", -1.0), ("invalid", -1.0)] {
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 503,
                                       httpVersion: nil, headerFields: ["Retry-After": raw])!
        check((TranslationRetry.retryAfter(response) ?? -1) == expected, "Retry-After parses safely: " + raw)
    }
    let now = Date(timeIntervalSince1970: 0)
    let dated = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 503,
                               httpVersion: nil, headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:00:20 GMT"])!
    check(TranslationRetry.retryAfter(dated, now: now) == 20, "HTTP-date Retry-After is supported")
    calls = 0
    let task = Task { @MainActor in
        try await TranslationRetry.run(sleep: { _ in throw CancellationError() }, onRetry: {}, operation: {
            calls += 1; throw TranslateError.retryable("busy")
        })
    }
    do { _ = try await task.value; fatalError("Cancellation accepted") }
    catch is CancellationError { check(calls == 1, "Cancellation during backoff prevents another request") }
    catch { fatalError("Cancellation classification lost") }
    // Exercise HTTP classification and wait hints together, without waiting in real time.
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TranslationFixtureProtocol.self]
    TranslationFixtureProtocol.responseCode = 503; TranslationFixtureProtocol.headers = ["Retry-After": "6"]
    waits = []; calls = 0
    let request = try! DeepSeekClient.request(text: "Hello.", kind: .sentence, direction: .toChinese, model: "deepseek-flash", key: "fixture")
    do {
        _ = try await TranslationRetry.run(delays: [2], sleep: { waits.append($0) }, onRetry: {}, operation: {
            calls += 1; return try await DeepSeekClient.stream(request, configuration: config) { _ in }
        })
        fatalError("503 accepted")
    } catch { check(calls == 2 && waits == [6] && error.localizedDescription.contains("status.deepseek.com"), "HTTP 503 respects wait hint and retains status-page guidance") }
    TranslationFixtureProtocol.headers = [:]; TranslationFixtureProtocol.responseCode = 200
    print("PASS: \(checks) service recovery fixtures")
}
