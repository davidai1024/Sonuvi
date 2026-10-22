// Sonuvi — GPL-3.0. Isolated signing validation; never reads user credentials.
import Foundation
import Security

func fail(_ operation: String, _ status: OSStatus) -> Never {
    fputs("\(operation) failed: \(status)\n", stderr); exit(1)
}
let data = FileHandle.standardInput.readDataToEndOfFile()
let input = try JSONSerialization.jsonObject(with: data) as! [String: String]
var interaction: DarwinBoolean = false
SecKeychainGetUserInteractionAllowed(&interaction)
SecKeychainSetUserInteractionAllowed(false)
defer { SecKeychainSetUserInteractionAllowed(interaction.boolValue) }
var keychain: SecKeychain?
let path = input["keychain"]!
let password = input["password"]!
if input["operation"] == "create" {
    var previous: CFArray?
    let copied = SecKeychainCopySearchList(&previous)
    guard copied == errSecSuccess, let previous else { fail("Read search list", copied) }
    let status = password.withCString { pointer in
        SecKeychainCreate(path, UInt32(password.utf8.count), pointer, false, nil, &keychain)
    }
    // A private build identity must not become the user's default/search keychain.
    let restored = SecKeychainSetSearchList(previous)
    guard restored == errSecSuccess else { fail("Restore search list", restored) }
    guard status == errSecSuccess else { fail("Create private keychain", status) }
} else {
    let opened = SecKeychainOpen(path, &keychain)
    guard opened == errSecSuccess else { fail("Open private keychain", opened) }
}
let unlocked = password.withCString { SecKeychainUnlock(keychain!, UInt32(password.utf8.count), $0, true) }
guard unlocked == errSecSuccess else { fail("Unlock private keychain", unlocked) }
if let archive = input["archive"] {
    var trusted: SecTrustedApplication?
    let trustedStatus = SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted)
    guard trustedStatus == errSecSuccess else { fail("Trust codesign tool", trustedStatus) }
    var access: SecAccess?
    let accessStatus = SecAccessCreate("Sonuvi Local Code Signing" as CFString, [trusted!] as CFArray, &access)
    guard accessStatus == errSecSuccess else { fail("Create signing-key ACL", accessStatus) }
    let options: [String: Any] = [kSecImportExportPassphrase as String: input["archivePassword"]!, kSecImportExportKeychain as String: keychain!, kSecImportExportAccess as String: access!]
    var items: CFArray?
    let imported = SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: archive)) as CFData, options as CFDictionary, &items)
    guard imported == errSecSuccess else { fail("Import signing identity", imported) }
}
print("Private keychain ready; user search list unchanged")
