import Foundation

enum CarrierError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct SIMLine: Identifiable, Equatable {
    let id: String
    let name: String
    let imsi: String
    let iccid: String
    let bundleID: String
    let version: String
    var mcc: String = ""
    var mnc: String = ""
    var selector: String? { try? SIMIdentity.selector(imsi: imsi, iccid: iccid) }
    var maskedIdentity: String { iccid.isEmpty ? "Идентификатор недоступен" : "SIM •••• " + iccid.suffix(4) }
}

enum SIMIdentity {
    static func normalizeICCID(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix("f"), text.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) {
            return String(text.dropLast())
        }
        return text
    }
    static func selector(imsi: String, iccid: String) throws -> String {
        let imsi = imsi.trimmingCharacters(in: .whitespacesAndNewlines)
        let iccid = normalizeICCID(iccid)
        guard (14...16).contains(imsi.count), (18...22).contains(iccid.count),
              (imsi + iccid).allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw CarrierError.message("iPhone не предоставил однозначные IMSI и ICCID этой SIM. Установка недоступна.")
        }
        return "\(imsi)_ID-\(iccid)_ID-.bundle"
    }
    static func matches(_ imsi: String, mcc: String, mnc: String) -> Bool {
        guard !mcc.isEmpty, !mnc.isEmpty else { return false }
        return [mnc, String(repeating: "0", count: max(0, 2 - mnc.count)) + mnc,
                String(repeating: "0", count: max(0, 3 - mnc.count)) + mnc].contains { imsi.hasPrefix(mcc + $0) }
    }
}

struct DeviceSnapshot {
    let product: String
    let hardware: String
    let version: String
    let build: String
    let udid: String
    let lines: [SIMLine]

    static func parse(_ values: [String: Any]) throws -> DeviceSnapshot {
        let rows = values["CarrierBundleInfoArray"] as? [[String: Any]] ?? []
        func text(_ dictionary: [String: Any], _ key: String) -> String { dictionary[key] as? String ?? "" }
        var lines = rows.enumerated().map { index, row -> SIMLine in
            let slot = text(row, "Slot")
            var imsi = text(row, "InternationalMobileSubscriberIdentity")
            var iccid = SIMIdentity.normalizeICCID(text(row, "IntegratedCircuitCardIdentity"))
            if iccid.isEmpty { iccid = SIMIdentity.normalizeICCID(text(row, "IntegratedCircuitCardIdentifier")) }
            if imsi.isEmpty || iccid.isEmpty {
                let suffixes = rows.count == 1 && slot == "kTwo" ? ["", "2"] : [(slot == "kTwo" || (slot.isEmpty && index == 1)) ? "2" : ""]
                let candidates = suffixes.compactMap { suffix -> (String, String)? in
                    let candidateIMSI = text(values, "InternationalMobileSubscriberIdentity" + suffix)
                    let candidateICCID = SIMIdentity.normalizeICCID(text(values, "IntegratedCircuitCardIdentity" + suffix).isEmpty
                        ? text(values, "IntegratedCircuitCardIdentifier" + suffix) : text(values, "IntegratedCircuitCardIdentity" + suffix))
                    guard SIMIdentity.matches(candidateIMSI, mcc: text(row, "MCC"), mnc: text(row, "MNC")),
                          (try? SIMIdentity.selector(imsi: candidateIMSI, iccid: candidateICCID)) != nil,
                          imsi.isEmpty || imsi == candidateIMSI, iccid.isEmpty || iccid == candidateICCID else { return nil }
                    return (candidateIMSI, candidateICCID)
                }
                if candidates.count == 1 { imsi = candidates[0].0; iccid = candidates[0].1 }
                else { imsi = ""; iccid = "" }
            }
            return SIMLine(id: slot.isEmpty ? "line-\(index)" : slot,
                           name: text(row, "CFBundleName").isEmpty ? "Линия \(index + 1)" : text(row, "CFBundleName"),
                           imsi: imsi, iccid: iccid,
                           bundleID: text(row, "CFBundleIdentifier"), version: text(row, "CFBundleVersion"),
                           mcc: text(row, "MCC"), mnc: text(row, "MNC"))
        }
        guard Set(lines.map(\.id)).count == lines.count else { throw CarrierError.message("iPhone вернул неоднозначные номера SIM-слотов.") }
        let selectors = lines.compactMap(\.selector)
        lines = lines.map { line in
            guard let selector = line.selector, selectors.filter({ $0 == selector }).count > 1 else { return line }
            return SIMLine(id: line.id, name: line.name, imsi: "", iccid: "", bundleID: line.bundleID, version: line.version, mcc: line.mcc, mnc: line.mnc)
        }
        let product = text(values, "ProductType"), hardware = text(values, "HardwareModel"), udid = text(values, "UniqueDeviceID")
        guard !product.isEmpty, !hardware.isEmpty, !udid.isEmpty else { throw CarrierError.message("Неполный ответ устройства.") }
        return DeviceSnapshot(product: product, hardware: hardware, version: text(values, "ProductVersion"),
                              build: text(values, "BuildVersion"), udid: udid, lines: lines)
    }
}

struct CarrierProfile: Codable, Identifiable {
    let path: String
    let name: String
    let identifier: String
    let version: String
    let supported: [String]
    let overrides: [[String]]
    var id: String { path }
    func compatibility(hardware: String, product: String) -> Int {
        let board = hardware.lowercased().hasSuffix("ap") ? String(hardware.dropLast(2)).lowercased() : hardware.lowercased()
        let accepted = Set([hardware.lowercased(), board, product.lowercased()])
        if !accepted.isDisjoint(with: supported.map { $0.lowercased() }) || overrides.contains(where: { $0.map { $0.lowercased() }.contains(board) }) { return 400 }
        if !overrides.isEmpty { return 50 }
        return supported.isEmpty ? 300 : 150
    }
}

struct APNEntry: Codable {
    let name: String
    let country: String
    let details: String
}
