import Foundation
import CryptoKit
import Argon2Swift

enum CryptoVaultError: LocalizedError {
    case payloadTooShort
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case emptyPassword

    var errorDescription: String? {
        switch self {
        case .payloadTooShort:
            return "File is corrupted or too small to be a valid vault archive."
        case .keyDerivationFailed:
            return "Argon2id key derivation failed."
        case .encryptionFailed:
            return "Failed to encrypt data payload."
        case .decryptionFailed:
            return "Authentication failed. Incorrect password or data corrupted."
        case .emptyPassword:
            return "Master password cannot be empty."
        }
    }
}

final class VaultCrypto {
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16

    /// Derives 256-bit symmetric key using Argon2id (m=64MB, t=3, p=4) matching desktop
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

    /// Encrypts an individual block using AES-256-GCM. Wire format: [12B Nonce] + [Ciphertext] + [16B Tag]
    static func encryptBlock(plainData: Data, using key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()
        guard let sealedBox = try? AES.GCM.seal(plainData, using: key, nonce: nonce),
              let combined = sealedBox.combined else {
            throw CryptoVaultError.encryptionFailed
        }
        return combined
    }

    /// Decrypts an individual AES-256-GCM block
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
}
