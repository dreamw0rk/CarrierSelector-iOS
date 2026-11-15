import Foundation

struct OperationContext: Codable, Equatable {
    let simKey: String
    let simLabel: String
    let previousID: String
    let previousVersion: String
    let targetID: String
    let targetVersion: String
    let activeID: String?
    let activeVersion: String?

    static func key(deviceHash: String, selectorHash: String) -> String {
        InstallReceipt.hash(deviceHash + ":" + selectorHash)
    }
    init?(device: DeviceSnapshot, line: SIMLine, target: CarrierProfile, restore: Bool = false) {
        guard let selector = line.selector else { return nil }
        simKey = Self.key(deviceHash: InstallReceipt.hash(device.udid), selectorHash: InstallReceipt.hash(selector))
        simLabel = line.maskedIdentity
        previousID = line.bundleID; previousVersion = line.version
        targetID = target.identifier; targetVersion = restore ? "" : target.version
        activeID = nil; activeVersion = nil
    }
    init(receipt: InstallReceipt, line: SIMLine?, active: SIMLine? = nil) {
        simKey = Self.key(deviceHash: receipt.deviceHash, selectorHash: receipt.selectorHash)
        simLabel = line?.maskedIdentity ?? "SIM предыдущей операции"
        previousID = receipt.previousID; previousVersion = receipt.previousVersion
        targetID = receipt.targetID; targetVersion = receipt.targetVersion
        activeID = active?.bundleID; activeVersion = active?.version
    }
}

struct HistorySIM: Identifiable {
    let id: String
    let label: String
}
