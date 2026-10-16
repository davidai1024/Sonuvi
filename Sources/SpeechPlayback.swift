// Sonuvi — GPL-3.0. Playback and metering use the same native audio clock.
import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class SpeechMeter: ObservableObject {
    @Published private(set) var levels = Array(repeating: 0.0, count: 24)
    func sample(decibels: Float) {
        let amplitude = decibels.isFinite ? min(1, max(0, pow(10, Double(decibels) / 20) * 3.5)) : 0
        levels = Array(levels.dropFirst()) + [amplitude < 0.025 ? 0 : amplitude]
    }
    func reset() { levels = Array(repeating: 0, count: 24) }
}

struct SpeechDots: View {
    @ObservedObject var meter: SpeechMeter
    var body: some View {
        FlowingDots(progress: 1, compact: true, animate: false, audioLevels: meter.levels)
            .frame(width: 88, height: 18).accessibilityHidden(true)
    }
}

enum ReadingPresentation { case floating, inline, settings }

@MainActor
final class SpeechPlayback: NSObject, AVAudioPlayerDelegate {
    let meter = SpeechMeter()
    private var process: Process?
    private var input: FileHandle?
    private var player: AVAudioPlayer?
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
        child.arguments = [bridge.path, "--root", RuntimeManager.root.path, "--service", service.path, "--native-player"]
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
            audio.delegate = self; audio.isMeteringEnabled = true; audio.prepareToPlay()
            guard audio.play() else { throw TranslateError.message("音频播放失败，请检查输出设备。") }
            player = audio; phaseChanged?("正在朗读")
            timer?.invalidate()
            let tick = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player else { return }
                    player.updateMeters()
                    self.meter.sample(decibels: player.averagePower(forChannel: 0))
                }
            }
            timer = tick; RunLoop.main.add(tick, forMode: .common); RunLoop.main.add(tick, forMode: .eventTracking)
        } catch { finish(.failure(error)) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.timer?.invalidate(); self.timer = nil; self.player = nil; self.meter.reset()
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
        player?.stop(); player = nil; timer?.invalidate(); timer = nil; meter.reset()
        let child = process; process = nil
        if child?.isRunning == true { child?.terminate() }
        try? input?.close(); input = nil
    }
}
