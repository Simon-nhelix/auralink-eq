import CryptoKit
import Foundation

// Adapted from MiSTer FTP (MIT); see third_party/licenses/MiSTer-FTP-LICENSE.

/// Ed25519 signatures of release archives.
///
/// The release script signs each archive with a private key kept in the
/// maintainer's keychain. The app carries only the public key (Info.plist key
/// `AuralinkUpdatePublicKey`), so a file swapped on GitHub will not install.
public enum UpdateSignature {
    public static func isValidPublicKey(_ text: String) -> Bool {
        guard let data = Data(base64Encoded: text) else { return false }
        return (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil
    }
    /// `signature` and `publicKey` are Base64 text; the key is the 32-byte raw form.
    public static func isValid(signature: String, for data: Data, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return key.isValidSignature(signatureData, for: data)
    }

    /// Base64 signature of `data`. The private key is the Base64 32-byte raw form.
    public static func sign(_ data: Data, privateKey: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateError.badSignature
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        return try key.signature(for: data).base64EncodedString()
    }
}
