// Sonuvi — GPL-3.0.
import Foundation
import AppKit

struct RuntimeInfo: Codable {
    let version: Int; let python: String; let model: String; let source: String
    let runtimeRevision: String?
}

@MainActor
final class RuntimeManager: ObservableObject {
    @Published var installing = false
    @Published var status = "尚未准备独立朗读环境"
    @Published var operationNotice = ""
    @Published var installationFailed = false
    private var cancelRequested = false
    @Published var ready = false
    @Published var usingLegacy = false
    @Published var removing = false
    @Published var diskUsage = ""
    private var process: Process?
    private var pending = Data()
    private var warmupProcess: Process?
    private var warmupTimer: Timer?
    private var warmupTimeout: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private var voiceProvider: (() -> String)?

    /// Load/compile silently after launch, while onboarding is visible, and
    /// after wake. A lightweight two-minute heartbeat prevents the engine's
    /// ten-minute idle exit while Sonuvi is running; it performs no inference.
    func startBackgroundWarmup(voice: @escaping () -> String) {
        guard voiceProvider == nil else { return }
        voiceProvider = voice
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.warmup() }
        }
        timer.tolerance = 15; warmupTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.warmup() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.warmup() }
    }
    func warmup() {
        guard voiceProvider != nil, !installing, !removing, warmupProcess == nil,
              let info = Self.info,
              let bridge = Bundle.main.url(forResource: "kokoro_bridge", withExtension: "py"),
              let service = Bundle.main.url(forResource: "kokoro_service", withExtension: "py") else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: info.python)
        child.arguments = ["-I", bridge.path, "--root", Self.root.path, "--service", service.path, "--warmup", "--voice", VoiceCatalog.option(voiceProvider?() ?? "af_heart").id]
        child.qualityOfService = .utility
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.warmupProcess === child else { return }
                self.warmupTimeout?.cancel(); self.warmupTimeout = nil; self.warmupProcess = nil
            }
        }
        do {
            try child.run(); warmupProcess = child
            let timeout = DispatchWorkItem { [weak self, weak child] in
                guard let child, self?.warmupProcess === child, child.isRunning else { return }; child.terminate()
            }
            warmupTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
        } catch { warmupProcess = nil } // Background failure never interrupts the UI; speech can retry.
    }
    func stopBackgroundWarmup() {
        voiceProvider = nil; warmupTimer?.invalidate(); warmupTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }; wakeObserver = nil
        warmupTimeout?.cancel(); warmupTimeout = nil
        if warmupProcess?.isRunning == true { warmupProcess?.terminate() }; warmupProcess = nil
    }
    static var root: URL {
        if Bundle.main.object(forInfoDictionaryKey: "MusePreview") as? Bool == true,
           let path = Bundle.main.object(forInfoDictionaryKey: "MuseDiagnosticsRuntime") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MuseTranslate/Voice", isDirectory: true)
    }
    var bundledRuntime: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appendingPathComponent("BundledVoice", isDirectory: true)
        return FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("runtime/bin/python3").path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) ? directory : nil
    }
    static var info: RuntimeInfo? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("ready.json")), let info = try? JSONDecoder().decode(RuntimeInfo.self, from: data) else { return nil }
        let owned = root.resolvingSymlinksInPath().path + "/"
        guard URL(fileURLWithPath: info.python).resolvingSymlinksInPath().path.hasPrefix(owned), URL(fileURLWithPath: info.model).resolvingSymlinksInPath().path.hasPrefix(owned), FileManager.default.isExecutableFile(atPath: info.python), FileManager.default.fileExists(atPath: info.model + "/kokoro-v1_0.safetensors") else { return nil }
        return info
    }
    var canImport: Bool {
        let cache = NSHomeDirectory() + "/.cache/huggingface/hub/models--mlx-community--Kokoro-82M-bf16/snapshots/a71e4d38b236d968966a2002c4c895dbd12b1c3c/"
        return FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.local/share/speak11/venv/bin/python3")
            && ["config.json", "kokoro-v1_0.safetensors"].allSatisfy { FileManager.default.fileExists(atPath: cache + $0) }
    }
    var displayStatus: String {
        if removing { return "正在移除本地朗读环境…" }
        if installing { return status }
        return ready ? "模型已就绪，可离线朗读" : "本地朗读尚未准备好"
    }
    func preparePreferred() {
        install(importExisting: bundledRuntime == nil && canImport, useBundled: bundledRuntime != nil)
    }
    func finishPreparation(succeeded: Bool, cancelled: Bool) {
        installationFailed = !succeeded && !cancelled
        if succeeded { operationNotice = "" }
        else if cancelled { operationNotice = ready ? "已取消本次操作，现有模型仍可使用。" : "已取消准备，可随时重试。" }
        else { operationNotice = ready ? "本次修复未完成，现有模型仍可使用。" : "准备未完成，请重试；仍失败时可在更多菜单中选择联网下载。" }
    }
    var availablePython: String? { Self.info?.python ?? (canImport ? NSHomeDirectory() + "/.local/share/speak11/venv/bin/python3" : nil) }
    func prepareBundledIfNeeded() {
        if let current = Self.info {
            let manifest = bundledRuntime.flatMap { try? Data(contentsOf: $0.appendingPathComponent("manifest.json")) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if let revision = manifest?["runtime_revision"] as? String, current.runtimeRevision != revision,
               !installing, !installationFailed {
                install(importExisting: false, useBundled: true)
                return
            }
            installAdditionalBundledVoices(); refresh(); return
        }
        guard bundledRuntime != nil, !installing else { return }
        install(importExisting: false, useBundled: true)
    }
    private func installAdditionalBundledVoices() {
        guard let bundle = bundledRuntime, let current = Self.info else { return }
        let target = URL(fileURLWithPath: current.model).appendingPathComponent("voices", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for voice in VoiceCatalog.all {
                let name = voice.id + ".safetensors"
                let source = bundle.appendingPathComponent("model/voices/" + name)
                let destination = target.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: source.path) {
                    try Data(contentsOf: source).write(to: destination, options: .atomic)
                }
            }
        } catch { status = "补充音色未完成，可在模型设置中重试。" }
    }
    func refresh() {
        ready = Self.info != nil; usingLegacy = !ready && canImport
        if !installing { status = ready ? "独立 Kokoro 已就绪" : (canImport ? "可导入已安装的 Speak11 环境" : "下载后可离线朗读") }
    }
    func install(importExisting: Bool, useBundled: Bool = false) {
        guard !installing, !removing, let setup = Bundle.main.url(forResource: "runtime_setup", withExtension: "py"), let uv = Bundle.main.url(forResource: "uv", withExtension: nil) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            let proc = Process(); let pipe = Pipe()
            var args = [setup.path, "--root", Self.root.path, "--uv", uv.path, "--mode", useBundled ? "bundled" : (importExisting ? "import" : "download")]
            if useBundled, let bundle = bundledRuntime { args += ["--bundle", bundle.path] }
            if useBundled, let bundle = bundledRuntime {
                proc.executableURL = bundle.appendingPathComponent("runtime/bin/python3"); proc.arguments = ["-I"] + args
            } else if let python = availablePython { proc.executableURL = URL(fileURLWithPath: python); proc.arguments = ["-I"] + args }
            else { proc.executableURL = uv; proc.arguments = ["run", "--no-project", "--python", "3.12", "--managed-python", "--script"] + args }
            var env = ProcessInfo.processInfo.environment
            env["UV_PYTHON_INSTALL_DIR"] = Self.root.appendingPathComponent("Python").path
            env["UV_CACHE_DIR"] = Self.root.appendingPathComponent("Cache/uv").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            proc.environment = env; proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
            operationNotice = ""; installationFailed = false; cancelRequested = false
            pending = Data(); status = useBundled ? "正在准备内置朗读环境，无需联网…" : "正在准备…"; installing = true; process = proc
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async { self?.receive(data) }
            }
            proc.terminationHandler = { [weak self] p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                DispatchQueue.main.async {
                    guard let self, self.process === p else { return }
                    self.receive(tail)
                    self.process = nil; self.installing = false; self.refresh()
                    if p.terminationStatus == 0 { self.warmup() }
                    self.finishPreparation(succeeded: p.terminationStatus == 0, cancelled: self.cancelRequested || p.terminationStatus == 130)
                }
            }
            try proc.run()
        } catch { installing = false; process = nil; refresh(); finishPreparation(succeeded: false, cancelled: false) }
    }
    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]; pending.removeSubrange(...newline)
            if let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String], row["stage"] != "progress", let message = row["message"] { status = message }
        }
    }
    func cancel() { guard process != nil else { return }; cancelRequested = true; process?.terminate() }
    func reveal() { NSWorkspace.shared.open(Self.root) }
    func remove() {
        guard !installing, !removing else { return }
        if warmupProcess?.isRunning == true { warmupProcess?.terminate() }
        removing = true
        let finish = { [weak self] in
            guard let self else { return }
            do {
                if FileManager.default.fileExists(atPath: Self.root.path) { try FileManager.default.trashItem(at: Self.root, resultingItemURL: nil) }
                self.refresh(); self.installationFailed = false; self.operationNotice = "本地朗读环境已移除，可随时重新准备。"
            } catch { self.operationNotice = "移除未完成，请退出应用后重试。" }
            self.removing = false
        }
        guard let info = Self.info, let bridge = Bundle.main.url(forResource: "kokoro_bridge", withExtension: "py"), let service = Bundle.main.url(forResource: "kokoro_service", withExtension: "py") else { finish(); return }
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: info.python)
        proc.arguments = [bridge.path, "--root", Self.root.path, "--service", service.path, "--shutdown"]
        proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { _ in DispatchQueue.main.async { finish() } }
        do { try proc.run() } catch { finish() }
    }
}
