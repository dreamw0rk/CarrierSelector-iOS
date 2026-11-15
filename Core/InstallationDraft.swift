import Foundation

/// Only the catalog path and hashes are persisted. A slot is not a stable SIM identity.
struct InstallationDraft: Codable, Equatable {
    var profilePath: String?
    var profileIdentifier: String?
    var profileVersion: String?
    var deviceHash: String?
    var selectorHash: String?

    mutating func select(line: SIMLine, device: DeviceSnapshot) {
        deviceHash = InstallReceipt.hash(device.udid)
        selectorHash = line.selector.map(InstallReceipt.hash)
    }
    func lineID(on device: DeviceSnapshot) -> String? {
        guard deviceHash == InstallReceipt.hash(device.udid), let selectorHash else { return nil }
        let matches = device.lines.filter { $0.selector.map(InstallReceipt.hash) == selectorHash }
        return matches.count == 1 ? matches.first?.id : nil
    }
    func profile(in profiles: [CarrierProfile]) -> CarrierProfile? {
        profiles.first { $0.path == profilePath && $0.identifier == profileIdentifier && $0.version == profileVersion }
    }
}

struct InstallationDraftStore {
    let defaults: UserDefaults
    private let key = "installation.draft.v1"
    func load() -> InstallationDraft {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(InstallationDraft.self, from: $0) }
            ?? InstallationDraft()
    }
    func save(_ draft: InstallationDraft) {
        if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: key) }
    }
}
