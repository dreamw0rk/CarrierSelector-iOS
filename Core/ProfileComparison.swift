import Foundation

enum ComparedValue: Equatable {
    case known(String), unknown, ambiguous
    var text: String {
        switch self {
        case .known(let text): return text
        case .unknown: return "Нет данных"
        case .ambiguous: return "Значения различаются"
        }
    }
    var isKnown: Bool { if case .known = self { return true }; return false }
    static func consensus(_ values: [String?]) -> Self {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return .unknown }
        let unique = Set(values.compactMap { $0 })
        return unique.count == 1 ? .known(unique.first!) : .ambiguous
    }
}

struct ProfileDifference: Identifiable {
    let id: String
    let title: String
    let current: ComparedValue
    let selected: ComparedValue
    var comparable: Bool { current.isKnown && selected.isKnown }
    var changed: Bool { comparable && current != selected }
}

/// Compares pinned catalog metadata for the exact reported version, not runtime modem state.
struct ProfileComparison {
    let rows: [ProfileDifference]
    let currentFound: Bool
    var changed: [ProfileDifference] { rows.filter(\.changed) }
    var unchanged: [ProfileDifference] { rows.filter { $0.comparable && !$0.changed } }
    var unknown: [ProfileDifference] { rows.filter { !$0.comparable } }

    init(current line: SIMLine, selected: CarrierProfile, device: DeviceSnapshot,
         profiles: [CarrierProfile], research: ProfileResearch) {
        let candidates = ProfileCatalogLookup.exact(identifier: line.bundleID, version: line.version, device: device, profiles: profiles)
        self.init(currentCandidates: candidates, targetCandidates: [selected], device: device, research: research)
    }

    init(first: CarrierProfile, second: CarrierProfile, device: DeviceSnapshot?, profiles: [CarrierProfile], research: ProfileResearch) {
        self.init(currentCandidates: ProfileCatalogLookup.exact(identifier: first.identifier, version: first.version, device: device, profiles: profiles),
                  targetCandidates: ProfileCatalogLookup.exact(identifier: second.identifier, version: second.version, device: device, profiles: profiles),
                  device: device, research: research)
    }

    private init(currentCandidates: [CarrierProfile], targetCandidates: [CarrierProfile], device: DeviceSnapshot?, research: ProfileResearch) {
        currentFound = !currentCandidates.isEmpty
        func settings(_ candidates: [CarrierProfile]) -> [ProfileCapabilities] {
            let variants = candidates.map { profile -> [ProfileCapabilities] in
                if let device, profile.compatibility(hardware: device.hardware, product: device.product) == 50 { return [] }
                return research.settings(for: profile, hardware: device?.hardware)
            }
            return variants.contains(where: \.isEmpty) ? [] : variants.flatMap { $0 }
        }
        let current = settings(currentCandidates), target = settings(targetCandidates)
        func flag(_ value: Bool?) -> String? { value.map { $0 ? "Включён" : "Выключен" } }
        let fields: [(String, String, (ProfileCapabilities) -> String?)] = [
            ("volte", "VoLTE по умолчанию", { flag($0.volte) }),
            ("wifi", "VoWiFi: подтверждение донора", { $0.wifiWithoutEntitlement.map { $0 ? "Не требуется" : "Требуется" } }),
            ("evs", "EVS в списке кодеков", { $0.evs.map { $0 ? "Есть" : "Нет" } }),
            ("5g", "Переключатель 5G", { $0.fiveGSwitch.map { $0 ? "Доступен" : "Скрыт" } }),
            ("apn", "APN интернета", { $0.apn.isEmpty ? nil : Set($0.apn).sorted().joined(separator: ", ") }),
            ("apnEdit", "Редактирование APN", { $0.apnEditable.map { $0 ? "Разрешено" : "Запрещено" } })
        ]
        rows = fields.map { id, title, value in
            ProfileDifference(id: id, title: title, current: .consensus(current.map(value)), selected: .consensus(target.map(value)))
        }
    }
}
