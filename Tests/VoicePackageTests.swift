// Sonuvi — GPL-3.0. Synthetic keys only; no user credentials or preferences.
import Foundation
import CryptoKit

func runVoicePackageTests() async {
    var count = 0
    func check(_ value: Bool, _ name: String) {
        guard value else { print("FAIL: \(name)"); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    let key = Curve25519.Signing.PrivateKey()
    var fixture: [String: Any] = ["format": 1, "sequence": 1, "packageVersion": "1", "architecture": "arm64",
        "minimumMacOS": "14.0", "minimumAppVersion": "0.4.22", "runtimeRevision": "runtime-test", "modelRevision": "model-test",
        "voices": VoiceCatalog.all.map(\.id), "bytes": 7, "expandedBytes": 100,
        "sha256": SHA256.hash(data: Data("fixture".utf8)).map { String(format: "%02x", $0) }.joined(),
        "downloadURL": "https://github.com/davidai1024/Sonuvi/releases/download/voice-kokoro-en-v1/fixture.tar.gz"]
    func signed(_ value: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()])
    }
    func verify(_ data: Data, version: String = "0.4.22", os: String = "14.0") throws -> VoicePackage {
        try VoicePackage.verify(data, publicKey: key.publicKey.rawRepresentation, appVersion: version, osVersion: os)
    }
    do {
        let data = try signed(fixture), package = try verify(data)
        check(package.sequence == 1 && package.voices.count == 28, "Signed compatible catalog is accepted")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: String]
        envelope["payload"] = Data("tampered".utf8).base64EncodedString()
        do { _ = try verify(JSONSerialization.data(withJSONObject: envelope)); check(false, "Tampered catalog must fail") }
        catch { check(true, "Tampering fails before any download or extraction") }
        do { _ = try VoicePackage.verify(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, appVersion: "0.4.22"); check(false, "Unknown signing key") }
        catch { check(true, "Untrusted signing key is rejected") }
        do { _ = try verify(data, version: "0.4.21"); check(false, "Too-old app") }
        catch { check(true, "New model cannot install on an incompatible app") }
        do { _ = try verify(data, os: "13.6"); check(false, "Too-old OS") }
        catch { check(true, "Model minimum macOS is enforced") }
        for change in [["downloadURL": "http://github.com/davidai1024/Sonuvi/releases/download/voice-kokoro-en-v1/fixture.tar.gz"],
                       ["downloadURL": "https://github.com/other/repo/releases/download/voice-kokoro-en-v1/fixture.tar.gz"],
                       ["sha256": "invalid"]] {
            var bad = fixture; change.forEach { bad[$0.key] = $0.value }
            do { _ = try verify(signed(bad)); check(false, "Invalid metadata") }
            catch { check(true, "Invalid download origin or checksum is rejected") }
        }
        fixture["sequence"] = 2
        do { _ = try verify(signed(fixture)); check(false, "Inconsistent version") }
        catch { check(true, "Catalog sequence and package version must agree") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sv-hash-" + UUID().uuidString)
        try Data("fixture".utf8).write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
        try package.verifyFile(temp); check(true, "Full downloaded file hash and size are verified")
        try Data("corrupt".utf8).write(to: temp)
        do { try package.verifyFile(temp); check(false, "Corrupt archive") }
        catch { check(true, "Same-size corruption is rejected before extraction") }
        check(VoicePackage.version("0.4.22", atLeast: "0.4.9") && !VoicePackage.version("0.4.9", atLeast: "0.4.22"), "Version comparison is numeric")
        for path in ["VoicePack/runtime/bin/python3", "VoicePack/model/voices/af_heart.safetensors"] {
            check(VoiceFileOperation.safeArchivePath(path), "Owned archive path is accepted")
        }
        for path in ["/tmp/escape", "VoicePack/../escape", "VoicePack/runtime/../../escape", "Other/file", "VoicePack//bad", "VoicePack/./bad", "VoicePack/evil\\path"] {
            check(!VoiceFileOperation.safeArchivePath(path), "Archive path cannot escape staging")
        }
        let bundled = try VoicePackage.bundled(); check(bundled.sequence >= 1, "App includes an independently verified fallback catalog")
        if let argument = CommandLine.arguments.firstIndex(of: "--voice-test-archive"), CommandLine.arguments.count > argument + 2 {
            let archive = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
            let destination = URL(fileURLWithPath: CommandLine.arguments[argument + 2])
            try bundled.verifyFile(archive)
            let bundle = try await VoiceFileOperation().unpack(archive, into: destination, package: bundled)
            try Data(bundle.path.utf8).write(to: destination.appendingPathComponent("bundle-path.txt"))
            check(true, "Real voice archive verifies and extracts with all 28 voices")
        }
    } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    print("PASS: \(count) voice package checks")
}

@MainActor
func runVoiceRuntimeTest() async {
    guard Bundle.main.object(forInfoDictionaryKey: "MusePreview") as? Bool == true,
          let path = Bundle.main.object(forInfoDictionaryKey: "MuseDiagnosticsRuntime") as? String,
          path.hasPrefix("/tmp/sv22-") else { print("FAIL: runtime test requires an isolated preview root"); exit(1) }
    let root = RuntimeManager.root
    let package: VoicePackage
    do { package = try VoicePackage.bundled() } catch { print("FAIL: catalog"); exit(1) }
    let runtime = RuntimeManager(); runtime.refresh()
    let before = try? Data(contentsOf: root.appendingPathComponent("ready.json"))
    runtime.downloadVoicePackage()
    var last = ""
    for _ in 0..<3600 {
        if runtime.status != last { last = runtime.status; print(last); fflush(stdout) }
        if !runtime.installing { break }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    guard runtime.ready, !runtime.installationFailed, RuntimeManager.info?.packageVersion == package.sequence else {
        print("FAIL: fresh download installation", runtime.operationNotice); exit(1)
    }
    guard let installed = try? Data(contentsOf: root.appendingPathComponent("ready.json")), installed != before else {
        print("FAIL: fresh marker was not committed"); exit(1)
    }
    print("PASS: full native download/verify/unpack/install pipeline committed a usable model"); fflush(stdout)
    if let archivePath = ProcessInfo.processInfo.environment["SONUVI_TEST_VOICE_ARCHIVE"] {
        do {
            let cache = root.appendingPathComponent("Downloads/" + package.sha256 + ".tar.gz")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: archivePath), to: cache)
        } catch { print("FAIL: cannot stage update fixture"); exit(1) }
        runtime.downloadVoicePackage()
        var cancelled = false
        for _ in 0..<3600 {
            if runtime.status == "正在检查环境与模型文件…" { runtime.cancel(); cancelled = true; break }
            if !runtime.installing { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for _ in 0..<200 {
            if !runtime.installing { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard cancelled, !runtime.installing, runtime.ready,
              (try? Data(contentsOf: root.appendingPathComponent("ready.json"))) == installed else {
            print("FAIL: cancelling an update changed the working model"); exit(1)
        }
        print("PASS: cancelling a real resource update keeps the previous working generation")
    }
    fflush(stdout); exit(0)
}
