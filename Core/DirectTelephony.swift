import Foundation
import CoreFoundation

enum DirectTelephonyMetric: String, CaseIterable {
    case context, imsVoice, imsSMS, imsConnection, attached, nrSA, nrNSA
    var title: String {
        switch self {
        case .context: return "Доступ к данным"
        case .imsVoice: return "Голос в IMS"
        case .imsSMS: return "SMS в IMS"
        case .imsConnection: return "Соединение IMS"
        case .attached: return "Регистрация для передачи данных"
        case .nrSA: return "Передача данных 5G SA"
        case .nrNSA: return "Передача данных 5G NSA"
        }
    }
}

struct DirectTelephonyReading: Identifiable {
    enum Status: String { case value, error, empty, unsupported, signature, exception, invalid }
    let slot: Int
    let metric: DirectTelephonyMetric
    let status: Status
    let value: Bool?
    let code: Int?
    let domain: String?
    let date: Date
    var id: String { "\(slot).\(metric.rawValue)" }
    var text: String {
        guard status == .value, let value else {
            switch status {
            case .error: return code.map { "Ошибка \($0)" } ?? "Ошибка запроса"
            case .unsupported: return "Недоступно в этой версии iOS"
            case .empty: return "Нет данных"
            case .signature, .invalid: return "Неизвестный формат ответа"
            case .exception: return "Не удалось выполнить запрос"
            case .value: return "Нет данных"
            }
        }
        switch metric {
        case .imsVoice, .imsSMS, .attached: return value ? "Зарегистрирован" : "Не зарегистрирован"
        case .imsConnection: return value ? "Есть" : "Не обнаружено"
        default: return value ? "Да" : "Нет"
        }
    }
    var reportLine: String {
        var result = "\(id): \(status.rawValue)"
        if let value { result += "=\(value)" }
        if let code { result += "; code=\(code); domain=\(domain ?? "other")" }
        return result
    }
    static func decode(_ raw: [[String: Any]]) -> [Self] {
        var seen = Set<String>()
        return raw.prefix(16).compactMap { row in
            guard let slot = row["slot"] as? Int, (0...2).contains(slot),
                  let name = row["metric"] as? String, let metric = DirectTelephonyMetric(rawValue: name),
                  let state = row["status"] as? String, let status = Status(rawValue: state),
                  let date = row["date"] as? Date, seen.insert("\(slot).\(name)").inserted else { return nil }
            let number = row["value"] as? NSNumber
            let bool = number.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
            let domains = ["kCTErrorDomain", "CTErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSOSStatusErrorDomain"]
            let domain = (row["domain"] as? String).flatMap { domains.contains($0) ? $0 : nil } ?? "other"
            return Self(slot: slot, metric: metric, status: status == .value && bool == nil ? .invalid : status,
                        value: status == .value ? bool : nil, code: status == .error ? row["code"] as? Int : nil,
                        domain: status == .error ? domain : nil, date: date)
        }
    }
}

/// Cancels subsequent calls and late delivery; an in-flight synchronous OS call cannot be interrupted.
final class DirectTelephonyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}
