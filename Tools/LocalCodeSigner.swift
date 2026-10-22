// Sonuvi — GPL-3.0. Build tool; passwords arrive on stdin, never in arguments.
import Foundation
import Security
let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
let path = input["keychain"] as! String; let password = input["password"] as! String
var keychain: SecKeychain?; var original: CFArray?
guard SecKeychainOpen(path, &keychain) == errSecSuccess,
      SecKeychainCopySearchList(&original) == errSecSuccess, let original else { exit(1) }
let unlocked = password.withCString { SecKeychainUnlock(keychain!, UInt32(password.utf8.count), $0, true) }
guard unlocked == errSecSuccess else { print("Unlock failed: \(unlocked)"); exit(1) }
var entries = original as! [SecKeychain]; entries.append(keychain!)
let added = SecKeychainSetSearchList(entries as CFArray)
guard added == errSecSuccess else { print("Search list failed: \(added)"); exit(1) }
var failed = false
for target in input["targets"] as! [String] {
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    child.arguments = ["--force", "--sign", input["fingerprint"] as! String, "--keychain", path, "--timestamp=none", target]
    do {
        try child.run()
        let watchdog = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)
        child.waitUntilExit(); watchdog.cancel()
        if child.terminationStatus != 0 { failed = true; break }
    }
    catch { print("Signing process failed"); failed = true; break }
}
let restored = SecKeychainSetSearchList(original)
guard restored == errSecSuccess else { print("RESTORE SEARCH LIST FAILED: \(restored)"); exit(2) }
print("Original keychain search list restored")
exit(failed ? 1 : 0)
