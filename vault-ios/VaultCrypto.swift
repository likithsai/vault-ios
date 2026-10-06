import Foundation
import CryptoKit
import Argon2Swift

enum CryptoVaultError: LocalizedError {
    case payloadTooShort
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case checksumMismatch(expected: String, actual: String)
    case emptyPassword

    var errorDescription: String? {
        switch self {
        case .payloadTooShort:
            return "File is corrupted or too small."
        case .keyDerivationFailed:
            return "Argon2 key derivation failed."
        case .encryptionFailed:
            return "Failed to encrypt data."
        case .decryptionFailed:
            return "Authentication failed or incorrect password."
        case .checksumMismatch(let exp, let act):
            return "Integrity check failed! Expected hash: \(exp.prefix(8))..., Got: \(act.prefix(8))..."
        case .emptyPassword:
            return "Master password cannot be empty."
        }
    }
}

final class VaultCrypto {
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16

    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        guard !password.isEmpty else { throw CryptoVaultError.emptyPassword }
        guard salt.count == saltLength else { throw CryptoVaultError.payloadTooShort }

        let saltObj = Salt(bytes: salt)
        let result = try Argon2Swift.hashPasswordString(
            password: password,
            salt: saltObj,
            iterations: 3,
            memory: 64 * 1024,
            parallelism: 4,
            length: 32,
            type: Argon2Type.id,
            version: Argon2Version.V13
        )
        return SymmetricKey(data: result.hashData())
    }

    static func encryptBlock(plainData: Data, using key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()
        guard let sealedBox = try? AES.GCM.seal(plainData, using: key, nonce: nonce),
              let combined = sealedBox.combined else {
            throw CryptoVaultError.encryptionFailed
        }
        return combined
    }

    static func decryptBlock(combinedCiphertext: Data, using key: SymmetricKey) throws -> Data {
        guard combinedCiphertext.count >= (nonceLength + tagLength) else {
            throw CryptoVaultError.payloadTooShort
        }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combinedCiphertext),
              let decrypted = try? AES.GCM.open(sealedBox, using: key) else {
            throw CryptoVaultError.decryptionFailed
        }
        return decrypted
    }

    /// Fast hardware-accelerated SHA-256 calculation
    static func computeSHA256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
