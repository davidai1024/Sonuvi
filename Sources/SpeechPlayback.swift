// Sonuvi — GPL-3.0. Playback and metering use the same native audio clock.
import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class SpeechMeter: ObservableObject {
    @Published private(set) var levels = Array(repeating: 0.0, count: 24)
    @Published private(set) var bands = Array(repeating: 0.0, count: SpeechAnalysis.frequencies.count)
    func sample(decibels: Float, spectrum: [Double]? = nil) {
        let amplitude = decibels.isFinite ? pow(min(1, max(0, (Double(decibels) + 50) / 44)), 1.8) : 0
        levels = Array(levels.dropFirst()) + [amplitude < 0.025 ? 0 : amplitude]
        let targets = spectrum ?? Array(repeating: amplitude, count: bands.count)
        bands = bands.enumerated().map { index, old in
            let target = index < targets.count ? min(1, max(0, targets[index])) : 0
            return old + (target - old) * (target > old ? 0.88 : 0.38)
        }
    }
    func reset() { levels = Array(repeating: 0, count: 24); bands = Array(repeating: 0, count: bands.count) }
}

/// Spectrum sampled from the actual WAV at AVAudioPlayer's playback position.
/// A short Hann window and logarithmic Goertzel bands keep this inexpensive.
struct SpeechAnalysis {
    static let frequencies = (0..<16).map { 90 * pow(65, Double($0) / 15) }
    private static let count = 1024
    private static let hann = (0..<count).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(count - 1)) }
    let samples: [Float]
    let sampleRate: Double
    init(samples: [Float], sampleRate: Double) { self.samples = samples; self.sampleRate = sampleRate }
    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= 5_000_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranslateError.message("音频无法分析。")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw TranslateError.message("音频无法分析。") }
        let frames = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        var mono = Array(repeating: Float(0), count: frames)
        for channel in 0..<channelCount { for index in 0..<frames { mono[index] += channels[channel][index] / Float(channelCount) } }
        samples = mono; sampleRate = buffer.format.sampleRate
    }
    func spectrum(at time: Double) -> [Double] {
        let start = Int(time * sampleRate) - Self.count / 2
        var window = Array(repeating: 0.0, count: Self.count), energy = 0.0
        for index in 0..<Self.count {
            let source = start + index
            let value = source >= 0 && source < samples.count ? Double(samples[source]) : 0
            energy += value * value; window[index] = value * Self.hann[index]
        }
        guard energy / Double(Self.count) > 0.000004 else { return Array(repeating: 0, count: Self.frequencies.count) }
        return Self.frequencies.map { frequency in
            guard frequency < sampleRate / 2 else { return 0 }
            let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
            var first = 0.0, second = 0.0
            for value in window { let current = value + coefficient * first - second; second = first; first = current }
            let power = max(1e-12, (first * first + second * second - coefficient * first * second) / Double(Self.count * Self.count))
            return min(1, max(0, (10 * log10(power) + 70) / 42))
        }
    }
}

struct SpeechDots: View {
    @ObservedObject var meter: SpeechMeter
    var body: some View {
        Canvas { context, size in
            let rows = 9, columns = meter.bands.count
            let stepX = size.width / CGFloat(columns), stepY = size.height / CGFloat(rows)
            let diameter: CGFloat = 1.8
            for column in 0..<columns {
                let level = meter.bands[column]
                for row in 0..<rows {
                    let distance = abs(Double(row) - Double(rows - 1) / 2)
                    let strength = min(1, max(0, level * Double(rows) / 2 - distance + 0.5))
                    let rect = CGRect(x: (CGFloat(column) + 0.5) * stepX - diameter / 2,
                                      y: (CGFloat(row) + 0.5) * stepY - diameter / 2,
                                      width: diameter, height: diameter)
                    let color = strength > 0.01 ? Color.green.opacity(0.4 + strength * 0.6) : Color.primary.opacity(row == rows / 2 ? 0.14 : 0)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }.frame(width: 88, height: 22).accessibilityHidden(true)
    }
}

enum ReadingPresentation { case floating, inline, settings }

@MainActor
final class SpeechPlayback: NSObject, AVAudioPlayerDelegate {
    let meter = SpeechMeter()
    private var process: Process?
    private var input: FileHandle?
    private var player: AVAudioPlayer?
    private var analysis: SpeechAnalysis?
    private var timer: Timer?
    private var completion: ((Result<Double, Error>) -> Void)?
    private var phaseChanged: ((String) -> Void)?
    private var finalMessage: [String: Any]?
    private var generation = UUID()

    func start(python: String, bridge: URL, service: URL, payload: Data,
               phase: @escaping (String) -> Void, completion: @escaping (Result<Double, Error>) -> Void) throws {
        stop()
        self.completion = completion; phaseChanged = phase; finalMessage = nil
        let id = generation
        let child = Process(); let incoming = Pipe(); let outgoing = Pipe()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-I", bridge.path, "--root", RuntimeManager.root.path, "--service", service.path, "--native-player"]
        child.standardInput = incoming; child.standardOutput = outgoing; child.standardError = FileHandle.nullDevice
        try child.run(); process = child; input = incoming.fileHandleForWriting
        do { try input?.write(contentsOf: payload + Data([10])) }
        catch { stop(); throw error }
        // One reader owns stdout; dispatch complete JSON lines in order, then EOF.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reader = outgoing.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id else { return }; self.receive(line)
                    }
                }
                if buffer.count > 1_000_000 { child.terminate(); break }
            }
            child.waitUntilExit(); try? reader.close()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == id else { return }
                let message = self.finalMessage
                if child.terminationStatus == 0, message?["status"] as? String == "ok" {
                    self.finish(.success(message?["audio_seconds"] as? Double ?? 0))
                } else {
                    self.finish(.failure(TranslateError.message(message?["message"] as? String ?? "本地朗读失败，请在设置中检查模型。")))
                }
            }
        }
    }
    private func receive(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            finish(.failure(TranslateError.message("本地朗读返回了无效数据。"))); return
        }
        guard object["event"] as? String == "audio", let path = object["path"] as? String else { finalMessage = object; return }
        do {
            let audio = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            analysis = try? SpeechAnalysis(url: URL(fileURLWithPath: path))
            audio.delegate = self; audio.isMeteringEnabled = true; audio.prepareToPlay()
            guard audio.play() else { throw TranslateError.message("音频播放失败，请检查输出设备。") }
            player = audio; phaseChanged?("正在朗读")
            timer?.invalidate()
            let tick = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player else { return }
                    player.updateMeters()
                    self.meter.sample(decibels: player.averagePower(forChannel: 0), spectrum: self.analysis?.spectrum(at: player.currentTime))
                }
            }
            timer = tick; RunLoop.main.add(tick, forMode: .common); RunLoop.main.add(tick, forMode: .eventTracking)
        } catch { finish(.failure(error)) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.timer?.invalidate(); self.timer = nil; self.player = nil; self.analysis = nil; self.meter.reset()
            guard flag else { self.finish(.failure(TranslateError.message("音频播放中断。"))); return }
            self.phaseChanged?("正在准备朗读…")
            do { try self.input?.write(contentsOf: Data("{\"action\":\"continue\"}\n".utf8)) }
            catch { self.finish(.failure(error)) }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.finish(.failure(TranslateError.message("音频解码失败。")))
        }
    }
    private func finish(_ result: Result<Double, Error>) {
        let callback = completion; stop(); callback?(result)
    }
    func stop() {
        generation = UUID(); completion = nil; phaseChanged = nil
        player?.stop(); player = nil; analysis = nil; timer?.invalidate(); timer = nil; meter.reset()
        let child = process; process = nil
        if child?.isRunning == true { child?.terminate() }
        try? input?.close(); input = nil
    }
}
