// Sonuvi — GPL-3.0. Independently signed voice resources, not app updates.
import Foundation
import CryptoKit

struct VoicePackage: Codable, Equatable {
    let format: Int
    let sequence: Int
    let packageVersion: String
    let architecture: String
    let minimumMacOS: String
    let minimumAppVersion: String
    let runtimeRevision: String
    let modelRevision: String
    let voices: [String]
    let bytes: Int64
    let expandedBytes: Int64
    let sha256: String
    let downloadURL: URL

    static func verify(_ envelope: Data, publicKey: Data, appVersion: String,
                       osVersion: String = "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)") throws -> VoicePackage {
        struct Envelope: Decodable { let payload: String; let signature: String }
        guard envelope.count <= 65_536,
              let signed = try? JSONDecoder().decode(Envelope.self, from: envelope),
              let payload = Data(base64Encoded: signed.payload), let signature = Data(base64Encoded: signed.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey), key.isValidSignature(signature, for: payload),
              let package = try? JSONDecoder().decode(Self.self, from: payload) else {
            throw TranslateError.message("语音资源签名验证失败，未安装任何文件。")
        }
        guard package.format == 1, package.sequence > 0, package.packageVersion == String(package.sequence),
              package.architecture == "arm64", package.bytes > 0, package.bytes <= 1_500_000_000,
              package.expandedBytes > 0, package.expandedBytes <= 4_000_000_000,
              package.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              package.downloadURL.scheme == "https", package.downloadURL.host == "github.com",
              package.downloadURL.user == nil, package.downloadURL.password == nil,
              package.downloadURL.port == nil, package.downloadURL.query == nil, package.downloadURL.fragment == nil,
              package.downloadURL.path.hasPrefix("/davidai1024/Sonuvi/releases/download/voice-kokoro-en-v\(package.sequence)/"),
              Set(package.voices) == Set(VoiceCatalog.all.map(\.id)), package.voices.count == 28 else {
            throw TranslateError.message("语音资源信息不完整或不兼容，未安装任何文件。")
        }
        guard Self.version(appVersion, atLeast: package.minimumAppVersion), Self.version(osVersion, atLeast: package.minimumMacOS) else {
            throw TranslateError.message("此语音资源需要更新的 Sonuvi 或 macOS，现有模型保持不变。")
        }
        return package
    }
    static func version(_ current: String, atLeast required: String) -> Bool {
        let a = current.split(separator: ".").compactMap { Int($0) }, b = required.split(separator: ".").compactMap { Int($0) }
        guard !a.isEmpty, !b.isEmpty, a.count == current.split(separator: ".").count, b.count == required.split(separator: ".").count else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }
    static func trusted(_ data: Data) throws -> VoicePackage {
        guard let keyURL = Bundle.main.url(forResource: "VoicePublicKey", withExtension: "txt"),
              let keyText = try? String(contentsOf: keyURL).trimmingCharacters(in: .whitespacesAndNewlines),
              let key = Data(base64Encoded: keyText) else { throw TranslateError.message("缺少语音资源验证信息，请重新下载 Sonuvi。") }
        return try verify(data, publicKey: key, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }
    static func bundled() throws -> VoicePackage {
        guard let url = Bundle.main.url(forResource: "VoiceCatalog", withExtension: "json") else { throw TranslateError.message("缺少语音资源下载信息，请重新下载 Sonuvi。") }
        return try trusted(Data(contentsOf: url))
    }
    func verifyFile(_ file: URL) throws {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard size?.int64Value == bytes else { throw TranslateError.message("语音资源下载不完整，请重试。") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw TranslateError.message("语音资源校验失败，请重新下载；现有模型保持不变。")
        }
    }
}

/// The downloader owns its delegate queue and continuation. Completion happens
/// once, after the temporary download has been moved to a persistent cache file.
final class VoiceDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let package: VoicePackage
    private let destination: URL
    private let resumeFile: URL
    private let progress: (Int64, Int64) -> Void
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished: URL?
    private var resultError: Error?
    private var cancelled = false
    private var usedResume = false
    private var received: Int64 = 0
    private var lastProgress: TimeInterval = 0
    init(package: VoicePackage, directory: URL, progress: @escaping (Int64, Int64) -> Void) {
        self.package = package; self.progress = progress
        destination = directory.appendingPathComponent(package.sha256 + ".tar.gz")
        resumeFile = directory.appendingPathComponent(package.sha256 + ".resume")
    }
    func download() async throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 7200
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil); self.session = session
            if let resume = try? Data(contentsOf: resumeFile) { usedResume = true; task = session.downloadTask(withResumeData: resume) }
            else { task = session.downloadTask(with: package.downloadURL) }
            task?.resume()
        }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }; cancelled = true
        task?.cancel(byProducingResumeData: { [resumeFile] data in if let data { try? data.write(to: resumeFile, options: .atomic) } })
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        received = totalBytesWritten
        if totalBytesWritten > package.bytes { resultError = TranslateError.message("语音资源大小异常，请重试。"); downloadTask.cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgress >= 0.1 || totalBytesWritten == package.bytes {
            lastProgress = now; progress(totalBytesWritten, package.bytes)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
                throw TranslateError.message("语音资源下载失败，请检查网络后重试。")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination); finished = destination
            try? FileManager.default.removeItem(at: resumeFile)
        } catch { resultError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        // Resume data can outlive URLSession's temporary partial file or its
        // signed CDN URL. Retry once from the immutable origin in that case.
        if error != nil && usedResume && received == 0 && !cancelled {
            usedResume = false; resultError = nil; finished = nil
            try? FileManager.default.removeItem(at: resumeFile)
            let fresh = session.downloadTask(with: package.downloadURL); self.task = fresh; fresh.resume()
            return
        }
        if let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? resume.write(to: resumeFile, options: .atomic) }
        let continuation = self.continuation; self.continuation = nil; self.task = nil
        session.invalidateAndCancel(); self.session = nil
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error = resultError ?? error { continuation?.resume(throwing: error) }
        else if let finished { continuation?.resume(returning: finished) }
        else { continuation?.resume(throwing: TranslateError.message("语音资源下载未完成，请重试。")) }
    }
}

/// Only subprocesses created by this operation can be terminated on cancel.
final class VoiceFileOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; if process?.isRunning == true { process?.terminate() } }
    func run(_ executable: URL, _ arguments: [String], outputLimit: Int = 8_000_000) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let child = Process(); child.executableURL = executable; child.arguments = arguments
                    let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
                    self.lock.lock()
                    if self.cancelled { self.lock.unlock(); throw CancellationError() }
                    self.process = child
                    do { try child.run() } catch { self.lock.unlock(); throw error }; self.lock.unlock()
                    var output = Data()
                    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                        output.append(chunk)
                        if output.count > outputLimit { child.terminate(); child.waitUntilExit(); throw TranslateError.message("语音资源文件列表异常，未切换模型。") }
                    }
                    child.waitUntilExit()
                    self.lock.lock(); self.process = nil; let cancelled = self.cancelled; self.lock.unlock()
                    if cancelled { throw CancellationError() }
                    guard child.terminationStatus == 0 else { throw TranslateError.message("语音资源解压失败，请重试；现有模型保持不变。") }
                    continuation.resume(returning: output)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func safeArchivePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 2048 && !path.contains("\\") && !path.contains("\0") && parts.first == "VoicePack"
            && parts.count > 1 && !parts.contains("..") && !parts.contains(".") && !parts.dropLast().contains("")
    }
    func unpack(_ archive: URL, into directory: URL, package: VoicePackage) async throws -> URL {
        let listing = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tzf", archive.path])
        guard let text = String(data: listing, encoding: .utf8) else { throw TranslateError.message("语音资源文件列表异常，未切换模型。") }
        let paths = text.split(separator: "\n").map(String.init)
        guard !paths.isEmpty, paths.count < 100_000, paths.allSatisfy(Self.safeArchivePath) else { throw TranslateError.message("语音资源路径异常，未切换模型。") }
        // This format has only regular files and directories. Reject links and
        // special entries before extraction, even from an authentic archive.
        let detail = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tvzf", archive.path])
        guard let types = String(data: detail, encoding: .utf8),
              types.split(separator: "\n").allSatisfy({ $0.first == "-" || $0.first == "d" }) else {
            throw TranslateError.message("语音资源含不支持的链接，未切换模型。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "--no-same-owner", "-C", directory.path])
        let bundle = directory.appendingPathComponent("VoicePack")
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]) else { throw TranslateError.message("语音资源解压失败，请重试；现有模型保持不变。") }
        var size: Int64 = 0
        for case let file as URL in enumerator {
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
            guard info.isSymbolicLink != true else { throw TranslateError.message("语音资源含不支持的链接，未切换模型。") }
            if info.isRegularFile == true { size += Int64(info.fileSize ?? 0) }
            guard size <= package.expandedBytes else { throw TranslateError.message("语音资源大小异常，请重试。") }
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("manifest.json"))) as? [String: Any]
        guard manifest?["package_version"] as? Int == package.sequence,
              manifest?["runtime_revision"] as? String == package.runtimeRevision,
              manifest?["revision"] as? String == package.modelRevision,
              FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("runtime/bin/python3").path),
              FileManager.default.fileExists(atPath: bundle.appendingPathComponent("model/kokoro-v1_0.safetensors").path),
              package.voices.allSatisfy({ FileManager.default.fileExists(atPath: bundle.appendingPathComponent("model/voices/" + $0 + ".safetensors").path) }) else { throw TranslateError.message("语音资源内容不完整，未切换模型。") }
        return bundle
    }
}
