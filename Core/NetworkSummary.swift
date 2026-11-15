import Foundation

/// CoreTelephony service identifiers are not Lockdown SIM slot identifiers.
/// Never infer SIM 1/2 from their ordering or suffixes.
struct RadioSnapshot: Equatable {
    let dataTechnology: String?
    let otherTechnologies: [String]
    static func make(services: [String: String], dataService: String?) -> RadioSnapshot {
        let dataTechnology = dataService.flatMap { services[$0] }.flatMap(technology)
        let others = services.filter { $0.key != dataService }.values.compactMap(technology).sorted()
        return RadioSnapshot(dataTechnology: dataTechnology, otherTechnologies: others)
    }
    static func technology(_ raw: String) -> String? {
        ["CTRadioAccessTechnologyGPRS": "2G · GPRS", "CTRadioAccessTechnologyEdge": "2G · EDGE",
         "CTRadioAccessTechnologyWCDMA": "3G · UMTS", "CTRadioAccessTechnologyHSDPA": "3G · HSDPA",
         "CTRadioAccessTechnologyHSUPA": "3G · HSUPA", "CTRadioAccessTechnologyCDMA1x": "CDMA 1x",
         "CTRadioAccessTechnologyCDMAEVDORev0": "3G · EVDO", "CTRadioAccessTechnologyCDMAEVDORevA": "3G · EVDO",
         "CTRadioAccessTechnologyCDMAEVDORevB": "3G · EVDO", "CTRadioAccessTechnologyeHRPD": "3G · eHRPD",
         "CTRadioAccessTechnologyLTE": "4G · LTE", "CTRadioAccessTechnologyNRNSA": "5G · NSA",
         "CTRadioAccessTechnologyNR": "5G · NR"][raw]
    }
}

enum DiagnosticMode: String, CaseIterable, Identifiable {
    case registration, call
    var id: String { rawValue }
    var title: String { self == .registration ? "Регистрация" : "Звонок" }
    var instructions: String {
        self == .registration
            ? "После начала сбора включите авиарежим на 10 секунд, оставив Wi-Fi включённым, затем выключите авиарежим. Вернитесь в приложение. При обрыве оно попробует подключиться снова."
            : "После начала сбора позвоните на другой номер и вернитесь в приложение. Не выключайте Wi-Fi и LocalDevVPN во время проверки."
    }
}

struct DiagnosticFieldCoverage {
    var seen = 0
    var redacted = 0
    var decoded = 0
    var status: String {
        if decoded > 0 { return "Получено" }
        if redacted > 0 { return "Скрыто iOS" }
        if seen > 0 { return "Нет результата" }
        return "Событий не было"
    }
}

struct DiagnosticStreamStats {
    var total = 0
    var commCenter = 0
    var redacted = 0
    var parsed = 0
    var invalidTimestamps = 0
    var reconnectAttempts = 0
    var coverage: [DiagnosticMetric: DiagnosticFieldCoverage] = [:]
    var availableMetrics: Set<DiagnosticMetric> { Set(coverage.filter { $0.value.decoded > 0 }.keys) }
    var hasDetailedMetrics: Bool {
        !availableMetrics.isDisjoint(with: [.imsVoice, .imsWiFi, .imsServices, .rsrp, .sinr, .sdpCodec, .callNetwork])
    }
    var explanation: String {
        if total == 0 { return "iPhone не передал события журнала." }
        if commCenter == 0 { return "Журнал доступен, но событий сотовой связи нет." }
        if parsed == 0 {
            return redacted > 0 ? "События связи получены, но iOS скрыла часть значений. Показатели не распознаны." : "События связи получены, но нужных показателей в них нет."
        }
        return hasDetailedMetrics ? "Получена часть показателей связи." : "Получены только общие сведения о сети. IMS, сигнал и параметры звонка недоступны."
    }
}

/// Retry only a previously opened stream, bounded by session time and attempts.
struct DiagnosticReconnectPolicy {
    private(set) var attempts = 0
    private var outageStarted: Date?
    mutating func recovered() { outageStarted = nil }
    mutating func shouldRetry(at now: Date, deadline: Date?) -> Bool {
        guard let deadline, now < deadline, attempts < 3 else { return false }
        let started = outageStarted ?? now
        guard now.timeIntervalSince(started) < 20 else { return false }
        outageStarted = started; attempts += 1
        return true
    }
}

/// Keeps counters, never raw events. Clock offsets must not silently empty a whole session.
final class DiagnosticCollector {
    private let parser = DiagnosticParser()
    private(set) var stats = DiagnosticStreamStats()
    func beginReconnect() { parser.resetConnection(); stats.reconnectAttempts += 1 }
    func ingest(process: String, category: String, message: String, timestamp: Int64, receivedAt: Date) -> [DiagnosticReading] {
        stats.total += 1
        guard (process as NSString).lastPathComponent == "CommCenter" else { return [] }
        stats.commCenter += 1
        if message.contains("<private>") || message.contains("<redacted>") { stats.redacted += 1 }
        let eventDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        // Preserve timestamps even when the two clocks differ. Mark unusable timestamps explicitly.
        let valid = eventDate >= Date(timeIntervalSince1970: 1_577_836_800) && eventDate <= receivedAt.addingTimeInterval(86_400)
        if !valid { stats.invalidTimestamps += 1 }
        // Assemble SIP by arrival time; the service clock can be skewed or missing.
        let values = parser.parse(process: process, category: category, message: message, date: receivedAt)
        if !values.isEmpty { stats.parsed += 1 }
        let evidence = DiagnosticParser.fieldEvidence(message: message, category: category)
        let decoded = Set(values.map(\.metric))
        for metric in Set(evidence.keys).union(decoded) {
            var field = stats.coverage[metric] ?? DiagnosticFieldCoverage()
            field.seen += 1
            if evidence[metric] == true { field.redacted += 1 }
            if decoded.contains(metric) { field.decoded += 1 }
            stats.coverage[metric] = field
        }
        return values.map { DiagnosticReading(slot: $0.slot, metric: $0.metric, value: $0.value,
                                               date: valid ? eventDate : receivedAt, timestampIsReceipt: !valid) }
    }
}
