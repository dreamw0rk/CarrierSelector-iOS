import Foundation
import CryptoKit

enum PairingRecord {
    static func validate(_ data: Data) throws {
        guard data.count < 2_000_000,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["identifier"] as? String, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32 else {
            throw CarrierError.message("Нужен Remote Pairing с identifier, private_key и public_key. Обычный Lockdown pairing-файл не подходит.")
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        guard key.publicKey.rawRepresentation == publicKey else {
            throw CarrierError.message("Открытый и закрытый ключи pairing не соответствуют друг другу.")
        }
        if let irk = plist["alt_irk"], (irk as? Data)?.count != 16 {
            throw CarrierError.message("Некорректный ключ идентификации устройства в pairing.")
        }
    }
}
