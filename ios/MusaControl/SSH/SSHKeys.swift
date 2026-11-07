import Foundation
import CryptoKit

/// The iPad's own SSH identity: an Ed25519 key generated on the device and
/// kept in the Keychain (this-device-only). Only the public key ever leaves.
enum SSHKeys {
    private static let keychainKey = "sshEd25519"

    static func privateKey() -> Curve25519.Signing.PrivateKey {
        if let raw = Keychain.get(keychainKey), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return k }
        let k = Curve25519.Signing.PrivateKey()
        Keychain.set(k.rawRepresentation, for: keychainKey)
        return k
    }

    static func reset() { Keychain.delete(keychainKey) }

    /// OpenSSH wire blob: string "ssh-ed25519" + string <32-byte key>.
    static func publicBlob(_ key: Curve25519.Signing.PublicKey) -> Data {
        var d = Data()
        func put(_ bytes: Data) { var len = UInt32(bytes.count).bigEndian; d.append(Data(bytes: &len, count: 4)); d.append(bytes) }
        put(Data("ssh-ed25519".utf8))
        put(key.rawRepresentation)
        return d
    }

    static func openSSHPublicKey(comment: String = "musa-control-ipad") -> String {
        "ssh-ed25519 \(publicBlob(privateKey().publicKey).base64EncodedString()) \(comment)"
    }

    static func fingerprint(blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static var ownFingerprint: String { fingerprint(blob: publicBlob(privateKey().publicKey)) }

    /// Fingerprint of an OpenSSH-format public key line ("type base64 [comment]").
    static func fingerprint(openSSH line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return fingerprint(blob: blob)
    }
}

/// Server SSH settings, pinned from the gateway over authenticated TLS.
struct SSHSettings: Codable, Equatable {
    var host: String
    var port: Int
    var user: String
    var pinnedFingerprints: [String]
    var keyInstalled: Bool

    static var stored: SSHSettings? {
        get { UserDefaults.standard.data(forKey: "sshSettings").flatMap { try? JSONDecoder().decode(SSHSettings.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "sshSettings") }
    }
}
