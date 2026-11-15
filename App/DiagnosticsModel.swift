import UIKit
import Combine

final class DiagnosticsModel: ObservableObject {
    @Published private(set) var mode = DiagnosticMode.registration
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var phase = "Готово к проверке"
    @Published private(set) var readings: [String: DiagnosticReading] = [:]
    @Published private(set) var stats = DiagnosticStreamStats()
    @Published private(set) var started: Date?
    @Published private(set) var ended: Date?
    @Published private(set) var deviceDescription: String?
    @Published private(set) var profiles: [String: String] = [:]
    @Published private(set) var error: String?
    private var session: DiagnosticSession?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func begin(mode: DiagnosticMode) -> DiagnosticSession {
        self.mode = mode
        let token = DiagnosticSession()
        session = token; running = true; stopping = false; error = nil
        readings = [:]; stats = DiagnosticStreamStats(); started = nil; ended = nil; profiles = [:]; deviceDescription = nil
        phase = "Подключение к iPhone…"
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Диагностика связи") { [weak self] in
            DispatchQueue.main.async {
                self?.stop(message: "iOS ограничила фоновую работу. Вернитесь в приложение для новой проверки.")
            }
        }
        return token
    }
    func attached(_ snapshot: DeviceSnapshot, token: DiagnosticSession) {
        guard session === token else { return }
        deviceDescription = "\(snapshot.product) · iOS \(snapshot.version)"
        profiles = Dictionary(uniqueKeysWithValues: snapshot.lines.map { ($0.id, "\($0.bundleID.replacingOccurrences(of: "com.apple.", with: "")) · \($0.version)") })
        phase = "Подключение диагностики…"
    }
    func collecting(token: DiagnosticSession) {
        guard session === token else { return }
        if started == nil { started = Date() }; phase = stopping ? "Остановка…" : "Получение данных…"
    }
    func reconnecting(token: DiagnosticSession) {
        guard session === token, !stopping else { return }
        phase = "Восстановление соединения…"
    }
    func update(_ values: [DiagnosticReading], stats: DiagnosticStreamStats, token: DiagnosticSession) {
        guard session === token else { return }
        for value in values where readings[value.id].map({ $0.date <= value.date }) ?? true {
            readings[value.id] = value
        }
        self.stats = stats
    }
    func stop(message: String = "Остановка…") {
        guard running else { return }
        stopping = true; phase = message; session?.stop()
    }
    func finish(token: DiagnosticSession, error: Error?) {
        guard session === token else { return }
        self.error = error?.localizedDescription
        running = false; stopping = false; ended = Date()
        phase = error != nil ? "Соединение прервано" : stats.explanation
        session = nil
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    var report: String {
        ["CarrierSelector " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
         deviceDescription ?? "Устройство не прочитано", phase,
         "Всего событий: \(stats.total)", "CommCenter: \(stats.commCenter)",
         "Скрытые значения: \(stats.redacted)", "Распознано событий: \(stats.parsed)",
         "Без корректной даты: \(stats.invalidTimestamps)", "Режим: \(mode.rawValue)",
         "Переподключений: \(stats.reconnectAttempts)",
         "Поля: " + Set(readings.values.map { $0.metric.rawValue }).sorted().joined(separator: ", "),
         "Состояние полей (упоминаний / скрыто / распознано):",
         DiagnosticMetric.allCases.map { metric in
             let value = stats.coverage[metric] ?? DiagnosticFieldCoverage()
             return "\(metric.rawValue): \(value.seen) / \(value.redacted) / \(value.decoded)"
         }.joined(separator: "\n")].joined(separator: "\n")
    }
    func reading(_ metric: DiagnosticMetric, slot: String) -> DiagnosticReading? { readings[slot + "." + metric.rawValue] }
    var slots: [String] {
        let known = Set(profiles.keys).union(readings.values.map(\.slot))
        return ["kOne", "kTwo", DiagnosticParser.general].filter { known.contains($0) }
    }
}
