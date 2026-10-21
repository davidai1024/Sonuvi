// Sonuvi — GPL-3.0.
import Foundation
import AppKit

struct RuntimeInfo: Codable {
    let version: Int; let python: String; let model: String; let source: String
    let runtimeRevision: String?
    let packageVersion: Int?
    let modelRevision: String?
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
    @Published var downloadProgress: Double?
    @Published var downloadBytes: Int64 = 0
    @Published var checkingForUpdates = false
    @Published var onlinePackage: VoicePackage?
    private var onlineTask: Task<Void, Never>?
    private var downloader: VoiceDownloader?
    private var fileOperation: VoiceFileOperation?
    private var downloadedBundle: URL?
    private var downloadedArchive: URL?
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
    var installedPackageVersion: Int {
        guard let current = Self.info else { return 0 }
        if let version = current.packageVersion { return version }
        // Existing full packages contain the exact first online voice pack.
        return current.runtimeRevision == "mlx-0.32.4-macos14-v1"
            && VoiceCatalog.all.allSatisfy { FileManager.default.fileExists(atPath: current.model + "/voices/" + $0.id + ".safetensors") } ? 1 : 0
    }
    var modelUpdateAvailable: Bool { (onlinePackage?.sequence ?? 0) > installedPackageVersion }
    var downloadSize: String { ByteCountFormatter.string(fromByteCount: onlinePackage?.bytes ?? 505_000_000, countStyle: .file) }
    var downloadDetail: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file) + " / " + downloadSize
    }
    private func latestPackage(fallback: Bool) async throws -> VoicePackage {
        do {
            var request = URLRequest(url: URL(string: "https://sonuvi.davidai1024.com/voice/latest.json")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let package = try VoicePackage.trusted(data)
            guard package.sequence >= installedPackageVersion else { throw TranslateError.message("已忽略较旧的语音资源，现有模型保持不变。") }
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try data.write(to: Self.root.appendingPathComponent("voice-catalog.json"), options: .atomic)
            return package
        } catch {
            try Task.checkCancellation()
            guard fallback else { throw error }
            if let data = try? Data(contentsOf: Self.root.appendingPathComponent("voice-catalog.json")),
               let cached = try? VoicePackage.trusted(data), cached.sequence >= installedPackageVersion { return cached }
            let bundled = try VoicePackage.bundled()
            guard bundled.sequence >= installedPackageVersion else { throw error }
            return bundled
        }
    }
    func checkForModelUpdates(quiet: Bool = false) {
        guard !checkingForUpdates, !installing, !removing else { return }
        checkingForUpdates = true
        Task { [weak self] in
            guard let self else { return }; defer { self.checkingForUpdates = false }
            do {
                self.onlinePackage = try await self.latestPackage(fallback: quiet)
                if !quiet { self.operationNotice = self.modelUpdateAvailable ? "有新的语音资源可下载，更新不需要重装 App。" : "语音资源已是最新版本。" }
            } catch { if !quiet { self.operationNotice = "无法检查模型更新，请检查网络后重试；现有模型仍可使用。" } }
        }
    }
    func preparePreferred() {
        if bundledRuntime != nil { install(importExisting: false, useBundled: true) }
        else { downloadVoicePackage() }
    }
    func downloadVoicePackage() {
        guard !installing, !removing else { return }
        installing = true; cancelRequested = false; installationFailed = false; operationNotice = ""
        downloadBytes = 0; downloadProgress = 0; status = "正在获取语音资源下载信息…"
        onlineTask = Task { [weak self] in
            guard let self else { return }
            var extraction: URL?
            do {
                let package = try await self.latestPackage(fallback: true); self.onlinePackage = package
                try Task.checkCancellation()
                let directory = Self.root.appendingPathComponent("Downloads")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let free = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
                guard (free?.int64Value ?? 0) >= max(2_500_000_000, package.expandedBytes * 2 + package.bytes) else {
                    throw TranslateError.message("可用磁盘空间不足，请至少预留 3GB。")
                }
                var archive = directory.appendingPathComponent(package.sha256 + ".tar.gz")
                let cachedArchive = archive
                let cached = await Task.detached(priority: .utility) { () -> Bool in
                    do { try package.verifyFile(cachedArchive); return true } catch { return false }
                }.value
                if !cached {
                    try? FileManager.default.removeItem(at: archive)
                    self.status = "正在下载本地语音资源…"
                    let downloader = VoiceDownloader(package: package, directory: directory) { [weak self] received, total in
                        DispatchQueue.main.async {
                            guard let self, self.downloader != nil else { return }
                            self.downloadBytes = received; self.downloadProgress = min(1, Double(received) / Double(max(1, total)))
                        }
                    }
                    self.downloader = downloader
                    archive = try await downloader.download(); self.downloader = nil
                }
                try Task.checkCancellation()
                self.downloadProgress = nil; self.status = "正在校验语音资源…"
                do { try await Task.detached(priority: .utility) { try package.verifyFile(archive) }.value }
                catch { try? FileManager.default.removeItem(at: archive); throw error }
                try Task.checkCancellation()
                let target = Self.root.appendingPathComponent("package-" + UUID().uuidString + ".partial")
                extraction = target; self.status = "正在解压语音资源…"
                let operation = VoiceFileOperation(); self.fileOperation = operation
                let bundle = try await operation.unpack(archive, into: target, package: package)
                self.fileOperation = nil; try Task.checkCancellation()
                self.downloadedBundle = target; self.downloadedArchive = archive
                self.onlineTask = nil; self.installing = false
                self.install(importExisting: false, useBundled: true, bundleOverride: bundle)
                // Setup owns the extraction until it has atomically committed.
                extraction = nil
            } catch {
                if let extraction { try? FileManager.default.removeItem(at: extraction) }
                self.downloader = nil; self.fileOperation = nil; self.onlineTask = nil
                self.installing = false; self.downloadProgress = nil; self.refresh()
                self.finishPreparation(succeeded: false, cancelled: self.cancelRequested || error is CancellationError)
                if !(self.cancelRequested || error is CancellationError) { self.operationNotice = error.localizedDescription }
            }
        }
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
    func install(importExisting: Bool, useBundled: Bool = false, bundleOverride: URL? = nil) {
        guard !installing, !removing, let setup = Bundle.main.url(forResource: "runtime_setup", withExtension: "py"), let uv = Bundle.main.url(forResource: "uv", withExtension: nil) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            let proc = Process(); let pipe = Pipe()
            var args = [setup.path, "--root", Self.root.path, "--uv", uv.path, "--mode", useBundled ? "bundled" : (importExisting ? "import" : "download")]
            let bundle = bundleOverride ?? bundledRuntime
            if useBundled, let bundle { args += ["--bundle", bundle.path] }
            if useBundled, let bundle {
                proc.executableURL = bundle.appendingPathComponent("runtime/bin/python3"); proc.arguments = ["-I"] + args
            } else if let python = availablePython { proc.executableURL = URL(fileURLWithPath: python); proc.arguments = ["-I"] + args }
            else { proc.executableURL = uv; proc.arguments = ["run", "--no-project", "--python", "3.12", "--managed-python", "--script"] + args }
            var env = ProcessInfo.processInfo.environment
            env["UV_PYTHON_INSTALL_DIR"] = Self.root.appendingPathComponent("Python").path
            env["UV_CACHE_DIR"] = Self.root.appendingPathComponent("Cache/uv").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            proc.environment = env; proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
            operationNotice = ""; installationFailed = false; cancelRequested = false
            pending = Data(); status = bundleOverride != nil ? "正在安装已下载的语音资源…" : useBundled ? "正在准备内置朗读环境，无需联网…" : "正在准备…"; installing = true; process = proc
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
                    self.cleanupDownloadedFiles(succeeded: p.terminationStatus == 0)
                }
            }
            try proc.run()
        } catch { installing = false; process = nil; refresh(); finishPreparation(succeeded: false, cancelled: false); cleanupDownloadedFiles(succeeded: false) }
    }
    private func cleanupDownloadedFiles(succeeded: Bool) {
        if let downloadedBundle { try? FileManager.default.removeItem(at: downloadedBundle) }
        if succeeded, let downloadedArchive { try? FileManager.default.removeItem(at: downloadedArchive) }
        downloadedBundle = nil; downloadedArchive = nil
    }
    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]; pending.removeSubrange(...newline)
            if let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String], row["stage"] != "progress", let message = row["message"] { status = message }
        }
    }
    func cancel() {
        guard process != nil || onlineTask != nil else { return }
        cancelRequested = true; onlineTask?.cancel(); downloader?.cancel(); fileOperation?.cancel(); process?.terminate()
    }
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
