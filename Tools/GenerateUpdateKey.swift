// One-time setup. Prints only the public key; refuses to overwrite a private key.
import CryptoKit
import Foundation
import Darwin

guard CommandLine.arguments.count == 2 else { exit(2) }
let key = Curve25519.Signing.PrivateKey()
let path = CommandLine.arguments[1]
let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
guard fd >= 0 else { fputs("Update key already exists or cannot be created.\n", stderr); exit(1) }
let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
do {
    try file.write(contentsOf: Data(key.rawRepresentation.base64EncodedString().utf8))
    try file.synchronize()
    try file.close()
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch { fputs("Could not save update key.\n", stderr); exit(1) }
