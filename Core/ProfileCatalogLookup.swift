import Foundation

enum ProfileCatalogLookup {
    static func exact(identifier: String, version: String, device: DeviceSnapshot?, profiles: [CarrierProfile]) -> [CarrierProfile] {
        let matches = profiles.filter { $0.identifier == identifier && $0.version == version }
        guard let device else { return matches.sorted { $0.path < $1.path } }
        let compatible = matches.filter { $0.compatibility(hardware: device.hardware, product: device.product) != 50 }
        let score = compatible.map { $0.compatibility(hardware: device.hardware, product: device.product) }.max()
        return compatible.filter { $0.compatibility(hardware: device.hardware, product: device.product) == score }.sorted { $0.path < $1.path }
    }
    static func versions(identifier: String, device: DeviceSnapshot?, profiles: [CarrierProfile]) -> [CarrierProfile] {
        Set(profiles.filter { $0.identifier == identifier }.map(\.version))
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .compactMap { exact(identifier: identifier, version: $0, device: device, profiles: profiles).first }
    }
}

extension RussianOperator {
    /// Resolve from the SIM's native catalog mapping, never from its installed donor bundle.
    static func inferred(nativeIdentifier: String?) -> Self? {
        switch nativeIdentifier {
        case "com.apple.MTS_ru": return .mts
        case "com.apple.MegaFon_ru": return .megafon
        case "com.apple.MegaFon_Yota_ru": return .yota
        case "com.apple.VimpelCom_ru": return .beeline
        case "com.apple.Tele2_ru": return .t2
        default: return nil
        }
    }
}
