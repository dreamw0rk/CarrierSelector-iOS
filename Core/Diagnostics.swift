import Foundation
import Darwin

enum DiagnosticMetric: String, CaseIterable, Identifiable {
    case registration, network, roaming, imsVoice, imsWiFi, volteCapability, vowifiCapability, vonrCapability
    case saSetting, rsrp, sinr, epdg, ikeState, ikeError, callNetwork, sdpCodec, imsServices
    var id: String { rawValue }
    var title: String {
        switch self {
        case .imsServices: return "Службы IMS"
        case .registration: return "Регистрация в сети"
        case .network: return "Радиосеть"
        case .roaming: return "Роуминг"
        case .imsVoice: return "Регистрация голоса в IMS"
        case .imsWiFi: return "Регистрация IMS через Wi-Fi"
        case .volteCapability: return "Поддержка VoLTE"
        case .vowifiCapability: return "Поддержка VoWiFi"
        case .vonrCapability: return "Поддержка VoNR"
        case .saSetting: return "Настройка 5G SA"
        case .rsrp: return "RSRP"
        case .sinr: return "SINR"
        case .epdg: return "Адрес ePDG"
        case .ikeState: return "Туннель IKE"
        case .ikeError: return "Последняя ошибка IKE"
        case .callNetwork: return "Сеть в SIP-ответе"
        case .sdpCodec: return "Кодек в SDP-ответе"
        }
    }
}

struct DiagnosticReading: Identifiable, Equatable {
    let slot: String
    let metric: DiagnosticMetric
    let value: String
    let date: Date
    var timestampIsReceipt = false
    var id: String { slot + "." + metric.rawValue }
}

/// Never retains a raw log entry. Only allowlisted scalar fields and SDP metadata survive parsing.
final class DiagnosticParser {
    private static let expressions: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>(); cache.countLimit = 128; return cache
    }()
    private struct SIPBuffer {
        var status: Int?
        var method: String?
        var network: String?
        var payloads: [String] = []
        var audioSections = 0
        var inAudio = false
        var codecs: [String: String] = [:]
        var slot: String
        var started: Date
    }
    private var sip: [String: SIPBuffer] = [:]
    static let general = "general"
    func resetConnection() { sip.removeAll() }
    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        let regex: NSRegularExpression
        if let cached = expressions.object(forKey: pattern as NSString) { regex = cached }
        else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
            expressions.setObject(compiled, forKey: pattern as NSString); regex = compiled
        }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    static func slot(message: String, category: String) -> String {
        var candidates = Set<String>()
        if let g = groups(#"^([12])\.\d+\s"#, message) { candidates.insert(g[0] == "1" ? "kOne" : "kTwo") }
        if let g = groups(#"\bslot (kOne|kTwo)\b"#, message) { candidates.insert(g[0]) }
        if let g = groups(#"\.([12])(?:\.\d+)?$"#, category) { candidates.insert(g[0] == "1" ? "kOne" : "kTwo") }
        return candidates.count == 1 ? candidates.first! : general
    }
    func parse(process: String, category: String, message: String, date: Date) -> [DiagnosticReading] {
        guard (process as NSString).lastPathComponent == "CommCenter", message.utf8.count <= 32_768 else { return [] }
        let slot = Self.slot(message: message, category: category)
        var result: [DiagnosticReading] = []
        func emit(_ metric: DiagnosticMetric, _ value: String) { result.append(DiagnosticReading(slot: slot, metric: metric, value: value, date: date)) }
        func flag(_ value: String) -> String { ["true", "ktrue"].contains(value.lowercased()) ? "Да" : "Нет" }
        if let g = Self.groups(#"(?i)IMS Voice registered\s*:\s*(true|false|kTrue|kFalse)\b"#, message) { emit(.imsVoice, flag(g[0])) }
        if let g = Self.groups(#"(?i)IMS registered\s*:\s*(true|false|kTrue|kFalse)\b"#, message) {
            if flag(g[0]) == "Нет" { emit(.imsWiFi, "Нет регистрации IMS") }
            else if let wifi = Self.groups(#"(?i)IMS registered\s*:\s*(?:true|kTrue)\s*,\s*Over Wifi\s*:\s*(true|false|kTrue|kFalse)\b"#, message) {
                emit(.imsWiFi, flag(wifi[0]) == "Да" ? "Зарегистрирован через Wi-Fi" : "IMS зарегистрирован, не через Wi-Fi")
            }
        }
        for (name, metric) in [("VoLTE", DiagnosticMetric.volteCapability), ("VoNR", .vonrCapability), ("VoWiFi", .vowifiCapability)] {
            if let g = Self.groups("(?i)" + name + #" Feature support\s*:\s*(true|false|kTrue|kFalse)\b"#, message) { emit(metric, flag(g[0])) }
        }
        if let g = Self.groups(#"UE is Registered for ((?:Voice|SMS|Video)(?:\+(?:Voice|SMS|Video))*) on (WLAN|WWAN|LTE|NR|WiFi|Wifi|Cellular)\b"#, message) {
            emit(.imsServices, g[0] + " · " + g[1])
        }
        if let g = Self.groups(#"Registration status is (kRegisteredHome|kRegisteredRoaming|kNotRegistered|kRegistrationDenied|kSearching)\b"#, message) {
            let labels = ["kRegisteredHome": "Домашняя сеть", "kRegisteredRoaming": "В роуминге", "kNotRegistered": "Не зарегистрирован", "kRegistrationDenied": "Отказ сети", "kSearching": "Поиск сети"]
            emit(.registration, labels[g[0]]!)
        }
        if let g = Self.groups(#"(?:current RAT \(|RAT remains at |current RAT set to )(kRatGSM|kRatUMTS|kRatLTE|kRatNR)\b"#, message) {
            emit(.network, ["kRatGSM": "2G · GSM", "kRatUMTS": "3G · UMTS", "kRatLTE": "4G · LTE", "kRatNR": "5G · NR"][g[0]]!)
        }
        if let g = Self.groups(#"Is device roaming: (kRoaming|kNotRoaming)\b"#, message) { emit(.roaming, g[0] == "kRoaming" ? "Да" : "Нет") }
        if let g = Self.groups(#"5G Standalone (enabled|disabled)\b"#, message) { emit(.saSetting, g[0] == "enabled" ? "Включена в настройках" : "Выключена") }
        if let g = Self.groups(#"\bRsrp\s*=\s*\{y\s*=\s*(-?\d+(?:\.\d+)?)\s*:"#, message), let value = Double(g[0]), (-160 ... -20).contains(value) {
            emit(.rsrp, String(format: "%.0f дБм", value))
        }
        if let g = Self.groups(#"\bSinr\s*=\s*\{y\s*=\s*(-?\d+(?:\.\d+)?)(?=\s*[:}])"#, message), let value = Double(g[0]), (-40 ... 60).contains(value) {
            emit(.sinr, String(format: "%.1f дБ", value))
        }
        if let g = Self.groups(#"<NEIKEv2Transport> UDP(?: NAT-T)? \S+ -> (\S+):(?:500|4500)\b"#, message) {
            let address = g[0].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var v4 = in_addr(), v6 = in6_addr()
            if inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1 {
                emit(.epdg, address + (["0.0.0.0", "::", "::1"].contains(address) || address.hasPrefix("127.") ? " · локальный/пустой адрес" : ""))
            }
        }
        if let g = Self.groups(#"IKEv2IKESA\[[^\]]*\] state (Invalid|Connecting|Authenticating|Established|Rekeying|Disconnected|Deleting|Dead) -> (Invalid|Connecting|Authenticating|Established|Rekeying|Disconnected|Deleting|Dead)\b"#, message) { emit(.ikeState, g[0] + " → " + g[1]) }
        if let g = Self.groups(#"NEIKEv2ErrorDomain Code=(\d{1,5})\b"#, message) { emit(.ikeError, "Код " + g[0]) }
        result += parseSIP(category: category, message: message, slot: slot, date: date)
        return result
    }

    static func fieldEvidence(message: String, category: String) -> [DiagnosticMetric: Bool] {
        guard message.utf8.count <= 32_768 else { return [:] }
        let fields: [(DiagnosticMetric, String, String)] = [
            (.imsVoice, "IMS Voice registered", #"IMS Voice registered\s*:\s*(<private>|<redacted>)"#),
            (.imsWiFi, "IMS registered", #"(?:IMS registered|Over Wifi)\s*:\s*(<private>|<redacted>)"#),
            (.imsServices, "UE is Registered for", #"UE is Registered for\s*(<private>|<redacted>)"#),
            (.volteCapability, "VoLTE Feature support", #"VoLTE Feature support\s*:\s*(<private>|<redacted>)"#),
            (.vonrCapability, "VoNR Feature support", #"VoNR Feature support\s*:\s*(<private>|<redacted>)"#),
            (.vowifiCapability, "VoWiFi Feature support", #"VoWiFi Feature support\s*:\s*(<private>|<redacted>)"#),
            (.registration, "Registration status is", #"Registration status is\s*(<private>|<redacted>)"#),
            (.network, "current RAT", #"current RAT(?: set to|\s*\()?\s*(<private>|<redacted>)"#),
            (.roaming, "Is device roaming", #"Is device roaming\s*:\s*(<private>|<redacted>)"#),
            (.rsrp, "Rsrp", #"Rsrp\s*=\s*(?:\{y\s*=\s*)?(<private>|<redacted>)"#),
            (.sinr, "Sinr", #"Sinr\s*=\s*(?:\{y\s*=\s*)?(<private>|<redacted>)"#),
            (.saSetting, "5G Standalone", #"5G Standalone\s*(<private>|<redacted>)"#),
            (.epdg, "<NEIKEv2Transport>", #"->\s*(<private>|<redacted>)"#),
            (.ikeState, "IKEv2IKESA", #"state\s*(?:(?:\w+|<private>|<redacted>)\s*->\s*)?(<private>|<redacted>)"#),
            (.ikeError, "NEIKEv2ErrorDomain", #"Code=\s*(<private>|<redacted>)"#)
        ]
        var result: [DiagnosticMetric: Bool] = [:]
        for (metric, marker, pattern) in fields where message.range(of: marker, options: .caseInsensitive) != nil {
            result[metric] = groups("(?i)" + pattern, message) != nil
        }
        if category.hasPrefix("sip.dump") {
            if message.contains("P-Access-Network-Info:") { result[.callNetwork] = groups(#"P-Access-Network-Info:\s*(<private>|<redacted>)"#, message) != nil }
            if message.contains("a=rtpmap:") || message.contains("m=audio ") {
                result[.sdpCodec] = groups(#"(?:a=rtpmap:\s*(?:\d+\s+)?|m=audio\s+\S+\s+\S+\s+(?:\d+\s+)*)(<private>|<redacted>)"#, message) != nil
            }
        }
        return result
    }

    private func parseSIP(category: String, message: String, slot: String, date: Date) -> [DiagnosticReading] {
        guard category.hasPrefix("sip.dump"), category.count <= 100 else { return [] }
        sip = sip.filter { (0...15).contains(date.timeIntervalSince($0.value.started)) }
        let line = message.replacingOccurrences(of: #"^[12]\.\d+\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty && line.allSatisfy({ $0 == "=" }) {
            guard let buffer = sip.removeValue(forKey: category), let status = buffer.status, (200..<300).contains(status),
                  ["INVITE", "PRACK", "UPDATE"].contains(buffer.method ?? ""), buffer.slot == slot else { return [] }
            var result: [DiagnosticReading] = []
            if let network = buffer.network { result.append(DiagnosticReading(slot: slot, metric: .callNetwork, value: network, date: date)) }
            // A single speech codec in an SDP response is evidence, not proof of a successful call.
            let codecs = Set(buffer.payloads.compactMap { buffer.codecs[$0] }.filter { $0 != "telephone-event" })
            if buffer.audioSections == 1, buffer.payloads.allSatisfy({ buffer.codecs[$0] != nil }), codecs.count == 1, let codec = codecs.first {
                result.append(DiagnosticReading(slot: slot, metric: .sdpCodec, value: codec, date: date))
            }
            return result
        }
        if line.hasPrefix("====") {
            if sip.count >= 16 { sip.removeAll() }
            sip[category] = SIPBuffer(slot: slot, started: date)
            return []
        }
        guard var buffer = sip[category], buffer.slot == slot else { sip.removeValue(forKey: category); return [] }
        if let g = Self.groups(#"^SIP/2\.0 (\d{3})\b"#, line) { buffer.status = Int(g[0]) }
        if let g = Self.groups(#"^CSeq: \d+ (INVITE|PRACK|UPDATE|REGISTER|OPTIONS)\b"#, line) { buffer.method = g[0] }
        if let g = Self.groups(#"^P-Access-Network-Info: (IEEE-802\.11|3GPP-E-UTRAN(?:-FDD|-TDD)?|3GPP-NR(?:-FDD|-TDD)?)\b"#, line) {
            buffer.network = g[0].hasPrefix("IEEE") ? "Wi-Fi" : g[0].hasPrefix("3GPP-NR") ? "5G NR" : "LTE"
        }
        if line.hasPrefix("m=") {
            buffer.inAudio = line.hasPrefix("m=audio ")
            if buffer.inAudio { buffer.audioSections += 1; buffer.payloads = []; buffer.codecs = [:] }
        }
        if let g = Self.groups(#"^m=audio [1-9]\d* RTP/AVP ([\d ]+)$"#, line) {
            let payloads = g[0].split(separator: " ").map(String.init)
            if payloads.count <= 32 { buffer.payloads = payloads }
        }
        if buffer.inAudio, let g = Self.groups(#"^a=rtpmap:(\d{1,3}) (EVS/16000|AMR-WB/16000|AMR/8000|telephone-event/\d+)\b"#, line) {
            buffer.codecs[g[0]] = g[1].hasPrefix("telephone-event") ? "telephone-event" : g[1]
        }
        sip[category] = buffer
        return []
    }
}

/// The close callback is armed only when the worker no longer uses the adapter handle.
/// Disarm waits for any close to return, preventing a use-after-free during FFI cleanup.
final class DiagnosticSession {
    private let lock = NSLock()
    private var stopped = false
    private var interrupt: (() -> Void)?
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { self.closeIfStopped() }
    }
    func arm(_ close: @escaping () -> Void) {
        lock.lock(); interrupt = close; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { self.closeIfStopped() }
    }
    func disarm() { lock.lock(); interrupt = nil; lock.unlock() }
    private func closeIfStopped() {
        lock.lock(); defer { lock.unlock() }
        if stopped, let interrupt { self.interrupt = nil; interrupt() }
    }
}
