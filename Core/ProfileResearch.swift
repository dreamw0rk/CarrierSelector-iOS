import Foundation

enum RussianOperator: String, CaseIterable, Identifiable {
    case all, mts, megafon, beeline, t2, yota, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все операторы РФ"
        case .mts: return "МТС"
        case .megafon: return "МегаФон"
        case .beeline: return "Билайн"
        case .t2: return "T2 / Tele2"
        case .yota: return "Yota"
        case .other: return "Другие / виртуальные"
        }
    }
}

struct ResearchSource: Decodable, Identifiable {
    let id: String
    let title: String
    let url: URL
    let checked: String
}

struct RussiaRule: Decodable, Identifiable {
    let identifier: String
    let versions: [String]
    let operators: [String]
    let candidate: Bool
    let reason: String
    let summary: String?
    let limitations: [String]
    let sourceIDs: [String]
    let scope: String
    var id: String { identifier + versions.joined(separator: ",") + operators.joined(separator: ",") }
    var operatorNames: String { operators.compactMap(RussianOperator.init(rawValue:)).map(\.title).joined(separator: ", ") }
    func matches(_ profile: CarrierProfile, operator selected: RussianOperator) -> Bool {
        identifier == profile.identifier && versions.contains(profile.version) &&
        (selected == .all || operators.contains(selected.rawValue))
    }
}

struct ResearchDocument: Decodable {
    let sources: [ResearchSource]
    let rules: [RussiaRule]
}

struct CapabilityRow: Identifiable {
    let id: String
    let title: String
    let value: String
}

/// Explicit settings from this archive's carrier.plist and the matching board override.
/// Missing settings remain unknown: country bundles/CommCenter defaults are not simulated.
struct ProfileCapabilities: Decodable {
    let boards: [String]
    let ims: Bool?
    let volte: Bool?
    let volteSwitch: Bool?
    let wifiWithoutEntitlement: Bool?
    let wifiRoaming: Bool?
    let wifiPriority: String?
    let wifiName: String?
    let evs: Bool?
    let fiveGSwitch: Bool?
    let apn: [String]
    let apnEditable: Bool?
    let epdg: String?
    let registration: [String]
    let conference: String?
    let xcap: Bool?

    func matches(hardware: String) -> Bool {
        let lower = hardware.lowercased()
        let board = lower.hasSuffix("ap") ? String(lower.dropLast(2)) : lower
        return boards.isEmpty || boards.contains { $0.lowercased() == board || $0.lowercased() == lower }
    }
    var blockers: [String] {
        var result: [String] = []
        if wifiWithoutEntitlement == false { result.append("Пакет требует подтверждения VoWiFi сервером оператора-донора.") }
        if let epdg, !epdg.isEmpty, !epdg.contains("$") {
            result.append("Адрес ePDG закреплён за оператором-донором; обычная установка не заменяет его.")
        }
        if registration.contains(where: { $0.range(of: "^(\\+|00|011)[0-9]{7,}$", options: .regularExpression) == nil }) {
            result.append("В пакете есть местный номер активации iMessage/FaceTime другой страны.")
        }
        return result
    }
    var rows: [CapabilityRow] {
        func flag(_ value: Bool?) -> String { value.map { $0 ? "Да" : "Нет" } ?? "Не указано" }
        func string(_ value: String?) -> String { value.flatMap { $0.isEmpty ? nil : $0 } ?? "Не указано" }
        let priority: String
        switch wifiPriority {
        case "wifi": priority = "Wi-Fi"
        case "ims": priority = "IMS (значение пакета)"
        case "cellular": priority = "Сотовая сеть"
        default: priority = string(wifiPriority)
        }
        return [
            CapabilityRow(id: "ims", title: "Поддержка IMS", value: flag(ims)),
            CapabilityRow(id: "volte", title: "VoLTE по умолчанию", value: flag(volte)),
            CapabilityRow(id: "volteSwitch", title: "Переключатель VoLTE", value: flag(volteSwitch)),
            CapabilityRow(id: "wifi", title: "VoWiFi без подтверждения донора", value: flag(wifiWithoutEntitlement)),
            CapabilityRow(id: "priority", title: "Приоритет звонков дома", value: priority),
            CapabilityRow(id: "roaming", title: "VoWiFi в роуминге", value: flag(wifiRoaming)),
            CapabilityRow(id: "evs", title: "Кодек EVS в настройках", value: flag(evs)),
            CapabilityRow(id: "5g", title: "Переключатель 5G", value: flag(fiveGSwitch)),
            CapabilityRow(id: "apn", title: "APN интернета", value: apn.isEmpty ? "Не указано" : apn.joined(separator: ", ")),
            CapabilityRow(id: "apnEdit", title: "Редактирование APN", value: flag(apnEditable)),
            CapabilityRow(id: "wifiName", title: "Подпись сети Wi-Fi", value: string(wifiName)),
            CapabilityRow(id: "activation", title: "Активация iMessage / FaceTime", value: registration.isEmpty ? "Не указано" : registration.joined(separator: ", ")),
            CapabilityRow(id: "conference", title: "Сервер конференций", value: string(conference)),
            CapabilityRow(id: "xcap", title: "Дополнительные услуги IMS (XCAP)", value: flag(xcap)),
            CapabilityRow(id: "epdg", title: "Шлюз звонков по Wi-Fi", value: string(epdg))
        ]
    }
}

struct ProfileResearch {
    let document: ResearchDocument
    let capabilities: [String: [ProfileCapabilities]]
    static let empty = ProfileResearch(document: ResearchDocument(sources: [], rules: []), capabilities: [:])

    init(document: ResearchDocument, capabilities: [String: [ProfileCapabilities]]) {
        self.document = document; self.capabilities = capabilities
    }
    init(directory: URL) throws {
        let decoder = JSONDecoder()
        document = try decoder.decode(ResearchDocument.self, from: Data(contentsOf: directory.appendingPathComponent("russia-research.json")))
        capabilities = try decoder.decode([String: [ProfileCapabilities]].self, from: Data(contentsOf: directory.appendingPathComponent("profile-capabilities.json")))
    }
    func rules(for profile: CarrierProfile, operator selected: RussianOperator = .all) -> [RussiaRule] {
        document.rules.filter { $0.matches(profile, operator: selected) }
    }
    func settings(for profile: CarrierProfile, hardware: String?) -> [ProfileCapabilities] {
        let variants = capabilities[profile.path] ?? []
        guard let hardware else { return variants }
        return variants.filter { $0.matches(hardware: hardware) }
    }
    func isCandidate(_ profile: CarrierProfile, operator selected: RussianOperator, hardware: String?) -> Bool {
        let matches = rules(for: profile, operator: selected)
        // A negative rule for a specific operator takes precedence over any positive note.
        if selected != .all && matches.contains(where: { !$0.candidate }) { return false }
        guard matches.contains(where: \.candidate) else { return false }
        return settings(for: profile, hardware: hardware).contains { $0.blockers.isEmpty }
    }
    func rows(for profile: CarrierProfile, hardware: String?) -> [CapabilityRow] {
        let settings = settings(for: profile, hardware: hardware)
        guard let first = settings.first else { return [] }
        return first.rows.map { row in
            let values = Set(settings.compactMap { $0.rows.first(where: { $0.id == row.id })?.value })
            return CapabilityRow(id: row.id, title: row.title, value: values.count == 1 ? row.value : "Зависит от платы iPhone")
        }
    }
    func blockers(for profile: CarrierProfile, hardware: String?) -> [String] {
        Array(Set(settings(for: profile, hardware: hardware).flatMap(\.blockers))).sorted()
    }
}
