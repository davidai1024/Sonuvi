// Sonuvi — GPL-3.0. Isolated signing validation; never reads user credentials.
import Foundation
import Security
var interaction: DarwinBoolean = false
SecKeychainGetUserInteractionAllowed(&interaction)
SecKeychainSetUserInteractionAllowed(false)
defer { SecKeychainSetUserInteractionAllowed(interaction.boolValue) }
let parameters = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: String]
var keychain: SecKeychain?
var status = SecKeychainOpen(parameters["keychain"]!, &keychain)
guard status == errSecSuccess else { print("OPEN_STATUS \(status)"); exit(1) }
let password = parameters["password"]!
status = password.withCString { SecKeychainUnlock(keychain!, UInt32(password.utf8.count), $0, true) }
guard status == errSecSuccess else { print("UNLOCK_STATUS \(status)"); exit(1) }
#if SECOND_VERSION
let revision = 2
#else
let revision = 1
#endif
let service = "com.wusir.sonuvi.signing-upgrade-fixture"
if parameters["operation"] == "create" {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecUseKeychain as String: keychain!, kSecAttrService as String: service, kSecAttrAccount as String: "synthetic", kSecValueData as String: Data("synthetic-upgrade-fixture-only".utf8)]
    status = SecItemAdd(query as CFDictionary, nil)
    print("CREATE_STATUS \(status); REVISION \(revision)"); exit(status == errSecSuccess ? 0 : 1)
}
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecMatchSearchList as String: [keychain!], kSecAttrService as String: service, kSecAttrAccount as String: "synthetic", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
var output: CFTypeRef?
status = SecItemCopyMatching(query as CFDictionary, &output)
let matches = status == errSecSuccess && (output as? Data) == Data("synthetic-upgrade-fixture-only".utf8)
print("READ_STATUS \(status); MATCH \(matches); REVISION \(revision)")
exit(matches ? 0 : 2)
