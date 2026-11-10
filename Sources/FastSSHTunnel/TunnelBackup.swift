import CommonCrypto
import CryptoKit
import Foundation

struct TunnelBackup: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let profile: TunnelProfile
        let password: String?
    }

    let entries: [Entry]
    static let fileExtension = "fastsshbackup"
    static let minimumPassphraseLength = 12

    private struct EncryptedFile: Codable {
        let version: Int
        let salt: Data
        let sealedData: Data
    }

    func write(to url: URL, passphrase: String) throws {
        guard passphrase.count >= Self.minimumPassphraseLength else { throw BackupError.shortPassphrase }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let key = try Self.encryptionKey(passphrase: passphrase, salt: salt)
        let payload = try JSONEncoder().encode(self)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let sealedData = sealed.combined else { throw BackupError.encryptionFailed }
        let file = EncryptedFile(version: 1, salt: salt, sealedData: sealedData)
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }

    static func read(from url: URL, passphrase: String) throws -> TunnelBackup {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(EncryptedFile.self, from: data) else { throw BackupError.invalidFile }
        guard file.version == 1 else { throw BackupError.unsupportedVersion }
        guard file.salt.count == 16 else { throw BackupError.invalidFile }
        let key = try encryptionKey(passphrase: passphrase, salt: file.salt)
        guard let sealed = try? AES.GCM.SealedBox(combined: file.sealedData),
              let payload = try? AES.GCM.open(sealed, using: key) else {
            throw BackupError.cannotUnlock
        }
        guard let backup = try? decoder.decode(TunnelBackup.self, from: payload),
              Set(backup.entries.map(\.profile.id)).count == backup.entries.count else {
            throw BackupError.invalidFile
        }
        return backup
    }

    private static func encryptionKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        let password = passphrase.precomposedStringWithCanonicalMapping
        let passwordLength = password.utf8.count
        let keyLength = 32
        var key = [UInt8](repeating: 0, count: keyLength)
        let status = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                // Version 1 fixes the iteration count so files cannot request unbounded work.
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordLength,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &key, keyLength
                )
            }
        }
        guard status == kCCSuccess else { throw BackupError.encryptionFailed }
        return SymmetricKey(data: key)
    }
}

enum BackupError: LocalizedError, Equatable {
    case shortPassphrase
    case encryptionFailed
    case invalidFile
    case unsupportedVersion
    case cannotUnlock
    case busy

    var errorDescription: String? {
        switch self {
        case .shortPassphrase: "Use a backup passphrase of at least \(TunnelBackup.minimumPassphraseLength) characters."
        case .encryptionFailed: "Could not encrypt or unlock the backup."
        case .invalidFile: "Choose a valid FastSSHTunnel backup file."
        case .unsupportedVersion: "This backup was created with a different version of FastSSHTunnel."
        case .cannotUnlock: "The passphrase is incorrect or the backup file is damaged."
        case .busy: "Wait for the current backup, restore, or password save to finish, then try again."
        }
    }
}
