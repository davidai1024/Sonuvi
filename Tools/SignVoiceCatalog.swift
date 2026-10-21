// Sonuvi — GPL-3.0. Keep the private key outside version control.
import Foundation
import CryptoKit
let args = CommandLine.arguments
let keyURL = URL(fileURLWithPath: args[1])
let key: Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath: keyURL.path) {
    key = try .init(rawRepresentation: Data(contentsOf: keyURL))
} else {
    key = .init()
    try key.rawRepresentation.write(to: keyURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
}
if args.count == 3 {
    try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: args[2]))
} else {
    if args.count >= 5 {
        let expected = try String(contentsOfFile: args[4]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.publicKey.rawRepresentation.base64EncodedString() == expected else {
            fputs("The signing key does not match the app's trusted public key.\n", stderr); exit(1)
        }
    }
    let payload = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let envelope = ["payload": payload.base64EncodedString(), "signature": try key.signature(for: payload).base64EncodedString()]
    try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[3]))
}
