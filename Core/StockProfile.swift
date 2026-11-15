import Foundation
import CryptoKit

struct NativeCatalog: Decodable {
    struct Family: Decodable {
        let products: [String]
        let hardwares: [String]
        let roots: [String]
    }
    let families: [Family]
    let supportedSIMs: [String: [String]]

    func profile(for line: SIMLine, device: DeviceSnapshot, profiles: [CarrierProfile]) -> CarrierProfile? {
        guard line.mcc.count == 3, (1...3).contains(line.mnc.count),
              (line.mcc + line.mnc).allSatisfy({ $0.isASCII && $0.isNumber }),
              line.selector != nil, SIMIdentity.matches(line.imsi, mcc: line.mcc, mnc: line.mnc),
              let family = families.first(where: { $0.products.contains(device.product) && $0.hardwares.contains(where: { $0.lowercased() == device.hardware.lowercased() }) }) else { return nil }
        let codes = Set([line.mcc + line.mnc, line.mcc + String(repeating: "0", count: max(0, 2 - line.mnc.count)) + line.mnc,
                         line.mcc + String(repeating: "0", count: max(0, 3 - line.mnc.count)) + line.mnc].filter { line.imsi.hasPrefix($0) })
        for root in family.roots {
            let matches = profiles.filter {
                $0.path.hasPrefix(root + "/") &&
                !codes.isDisjoint(with: supportedSIMs[$0.path] ?? []) &&
                $0.compatibility(hardware: device.hardware, product: device.product) != 50
            }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }
}

enum StockReset {
    /// Same reset mechanism as upstream build_reset_payload: only SupportedSIMs changes.
    /// Caller must validate the pinned archive and select the SIM's own carrier first.
    static func files(from files: [(String, Data)], expectedIdentifier: String) throws -> [(String, Data)] {
        guard let infoData = files.first(where: { $0.0 == "Info.plist" })?.1,
              let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == expectedIdentifier,
              let original = files.first(where: { $0.0 == "carrier.plist" })?.1,
              var carrier = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any],
              carrier["SupportedSIMs"] is [String] else {
            throw CarrierError.message("Не удалось проверить пакет штатного оператора. Сброс не отправлен.")
        }
        carrier["SupportedSIMs"] = [String]()
        let data = try PropertyListSerialization.data(fromPropertyList: carrier,
            format: original.starts(with: Data("bplist".utf8)) ? .binary : .xml, options: 0)
        return files.map { ($0.0, $0.0 == "carrier.plist" ? data : $0.1) }
    }
}

struct InstallReceipt: Codable {
    let deviceHash: String
    let selectorHash: String
    let targetID: String
    let targetVersion: String
    let previousID: String
    let previousVersion: String
    let date: Date
    var operation: String? = nil // nil preserves receipts written before rollback support.
    var isRestore: Bool { operation == "restoreStock" }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func matches(device: DeviceSnapshot, line: SIMLine) -> Bool {
        Self.hash(device.udid) == deviceHash && line.selector.map(Self.hash) == selectorHash
    }
    func verified(on device: DeviceSnapshot, restartConfirmed: Bool) -> Bool {
        ProfileVerification(receipt: self, device: device, restartConfirmed: restartConfirmed).confirmed
    }
}
