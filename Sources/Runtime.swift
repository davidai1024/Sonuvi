// Sonuvi — GPL-3.0.
import Foundation
import AppKit

struct RuntimeInfo: Codable { let version: Int; let python: String; let model: String; let source: String }

@MainActor
final class RuntimeManager: ObservableObject {
    @Published var installing = false
    @Published var status = "尚未准备独立朗读环境"
    @Published var ready = false
    @Published var usingLegacy = false
    @Published var removing = false
    @Published var diskUsage = ""
    private var process: Process?
    private var pending = Data()
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MuseTranslate/Voice", isDirectory: true) }
    static var info: RuntimeInfo? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("ready.json")), let info = try? JSONDecoder().decode(RuntimeInfo.self, from: data) else { return nil }
        let owned = root.resolvingSymlinksInPath().path + "/"
        guard URL(fileURLWithPath: info.python).resolvingSymlinksInPath().path.hasPrefix(owned), URL(fileURLWithPath: info.model).resolvingSymlinksInPath().path.hasPrefix(owned), FileManager.default.isExecutableFile(atPath: info.python), FileManager.default.fileExists(atPath: info.model + "/kokoro-v1_0.safetensors") else { return nil }
        return info
    }
    var canImport: Bool { FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.local/share/speak11/venv/bin/python3") }
    var availablePython: String? { Self.info?.python ?? (canImport ? NSHomeDirectory() + "/.local/share/speak11/venv/bin/python3" : nil) }
    func refresh() {
        ready = Self.info != nil; usingLegacy = !ready && canImport
        if !installing { status = ready ? "独立 Kokoro 已就绪" : (canImport ? "可导入已安装的 Speak11 环境" : "下载后可离线朗读") }
    }
    func install(importExisting: Bool) {
        guard !installing, !removing, let setup = Bundle.main.url(forResource: "runtime_setup", withExtension: "py"), let uv = Bundle.main.url(forResource: "uv", withExtension: nil) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            let proc = Process(); let pipe = Pipe()
            let args = [setup.path, "--root", Self.root.path, "--uv", uv.path, "--mode", importExisting ? "import" : "download"]
            if let python = availablePython { proc.executableURL = URL(fileURLWithPath: python); proc.arguments = args }
            else { proc.executableURL = uv; proc.arguments = ["run", "--no-project", "--python", "3.12", "--managed-python", "--script"] + args }
            var env = ProcessInfo.processInfo.environment
            env["UV_PYTHON_INSTALL_DIR"] = Self.root.appendingPathComponent("Python").path
            env["UV_CACHE_DIR"] = Self.root.appendingPathComponent("Cache/uv").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            proc.environment = env; proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
            pending = Data(); status = "正在准备…"; installing = true; process = proc
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
                    self.receive(tail); let last = self.status
                    self.process = nil; self.installing = false; self.refresh()
                    if p.terminationStatus != 0 { self.status = p.terminationStatus == 130 ? "已取消，可随时重试" : "安装未完成：\(last)" }
                }
            }
            try proc.run()
        } catch { installing = false; process = nil; status = "无法启动安装，请重新打开应用后重试。" }
    }
    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]; pending.removeSubrange(...newline)
            if let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String], row["stage"] != "progress", let message = row["message"] { status = message }
        }
    }
    func cancel() { process?.terminate() }
    func reveal() { NSWorkspace.shared.open(Self.root) }
    func remove() {
        guard !installing, !removing else { return }
        removing = true
        let finish = { [weak self] in
            guard let self else { return }
            do {
                if FileManager.default.fileExists(atPath: Self.root.path) { try FileManager.default.trashItem(at: Self.root, resultingItemURL: nil) }
                self.refresh(); self.status = "独立环境已移到废纸篓，可重新导入或下载。"
            } catch { self.status = "移除未完成，请退出应用后重试。" }
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
