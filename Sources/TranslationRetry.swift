// Sonuvi — GPL-3.0. Bounded recovery shared by dictionary and document requests.
import Foundation

enum TranslationRetry {
    static let delays: [TimeInterval] = [2, 4, 8, 16]

    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return min(seconds, 60) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(60, max(0, date.timeIntervalSince(now)))
    }

    @MainActor
    static func run(delays: [TimeInterval] = delays,
                    sleep: (TimeInterval) async throws -> Void = { seconds in
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    },
                    onRetry: () -> Void,
                    operation: () async throws -> String) async throws -> String {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch TranslateError.retryable(let message, let retryAfter) {
                try Task.checkCancellation()
                guard attempt < delays.count else { throw TranslateError.message(message) }
                let delay = max(delays[attempt], retryAfter ?? 0)
                attempt += 1
                onRetry()
                try await sleep(delay)
            }
        }
    }
}
