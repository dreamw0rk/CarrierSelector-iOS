import Foundation
import Security

enum PairingStore {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.carrierselector.remote-pairing", kSecAttrAccount as String: "device"] }
    static var exists: Bool { (try? read()) != nil }
    static func save(_ data: Data) throws {
        try PairingRecord.validate(data)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CarrierError.message("Не удалось сохранить pairing в Keychain: \(status).") }
    }
    static func read() throws -> Data {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ConnectionFailure(reason: status == errSecItemNotFound ? .missingPairing : status == errSecInteractionNotAllowed ? .locked : .keychain)
        }
        return data
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CarrierError.message("Не удалось удалить pairing: \(status).")
        }
    }
    static func withFile<T>(_ body: (URL) throws -> T) throws -> T {
        let data = try read()
        do { try PairingRecord.validate(data) }
        catch { throw ConnectionFailure(reason: .invalidPairing) }
        return try withFile(data: data, body)
    }
    static func withFile<T>(data: Data, _ body: (URL) throws -> T) throws -> T {
        try PairingRecord.validate(data)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
}
