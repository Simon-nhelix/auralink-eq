// Ed25519 release signatures. Private material stays in the login keychain.
// Usage: swift scripts/update-signing.swift generate | check | sign <archive>
import CryptoKit
import Foundation
import Security

let service = "Auralink EQ update signing key"
let account = "com.auralink.eq"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let releaseURL = root.appendingPathComponent("Resources/Release.plist")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8)); exit(1)
}

func readKey() -> Curve25519.Signing.PrivateKey? {
    var value: CFTypeRef?
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("cannot read the update key from Keychain (status \(status)); no key was replaced")
    }
    return key
}

var release = try PropertyListSerialization.propertyList(from: Data(contentsOf: releaseURL), format: nil) as! [String: Any]
let configuredKey = release["publicKey"] as? String ?? ""
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    let key: Curve25519.Signing.PrivateKey
    if let existing = readKey() { key = existing }
    else {
        guard configuredKey.isEmpty else { fail("the release public key is configured but the private key is missing. Restore its Keychain backup; generating a replacement would break installed apps") }
        key = Curve25519.Signing.PrivateKey()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecAttrLabel as String: service, kSecValueData as String: key.rawRepresentation]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { fail("cannot save update key to Keychain (status \(status))") }
    }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard configuredKey.isEmpty || configuredKey == publicKey else { fail("Keychain key differs from the configured release key; refusing to rotate it") }
    release["publicKey"] = publicKey
    try PropertyListSerialization.data(fromPropertyList: release, format: .xml, options: 0).write(to: releaseURL, options: .atomic)
    print("Update public key configured. Private key remains in Keychain: \(service)")
case "check", "sign":
    guard let key = readKey(), key.publicKey.rawRepresentation.base64EncodedString() == configuredKey else {
        fail("Keychain key does not match Resources/Release.plist")
    }
    if arguments.first == "sign" {
        guard arguments.count == 2 else { fail("usage: sign <archive>") }
        let archive = URL(fileURLWithPath: arguments[1])
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let signature = try key.signature(for: data)
        guard key.publicKey.isValidSignature(signature, for: data) else { fail("signature self-check failed") }
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: archive.path + ".sig"), options: .atomic)
        print("Signed and verified \(archive.lastPathComponent).sig")
    } else { print("Update signing key matches the release public key.") }
default: fail("usage: swift scripts/update-signing.swift generate | check | sign <archive>")
}
