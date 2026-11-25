// Signs a release archive for the updater, or makes the key pair that does it.
//   swift scripts/sign-update.swift --create-key           prints "<private key> <public key>" (base64)
//   swift scripts/sign-update.swift <archive> <version> <build> [notes]
//                                                           reads the private key on stdin, prints update.json
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--create-key" {
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
guard arguments.count >= 3, let build = Int(arguments[arguments.startIndex + 2]) else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <archive> <version> <build> [notes]\n".utf8))
    exit(2)
}
let archive = URL(fileURLWithPath: arguments[arguments.startIndex])
let version = arguments[arguments.startIndex + 1]
let notes = arguments.count > 3 ? arguments[arguments.startIndex + 3] : ""
let secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let keyData = Data(base64Encoded: secret), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
else {
    FileHandle.standardError.write(Data("No valid private key on stdin.\n".utf8))
    exit(1)
}
let data = try Data(contentsOf: archive)
let signature = try key.signature(for: data).base64EncodedString()
let formatter = ISO8601DateFormatter()
let feed: [String: Any] = [
    "version": version, "build": build, "archive": archive.lastPathComponent, "signature": signature,
    "notes": notes, "published": formatter.string(from: Date()),
]
let json = try JSONSerialization.data(withJSONObject: feed, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: json, as: UTF8.self))
