import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Combine

/// Main-thread state; private calls run serially off the UI thread and never need pairing.
final class DirectTelephonyModel: ObservableObject {
    @Published private(set) var readings: [DirectTelephonyReading] = []
    @Published private(set) var running = false
    @Published private(set) var waitingForCall = false
    @Published private(set) var phase = "Готово к проверке"
    private let worker = DispatchQueue(label: "CarrierSelector.direct-telephony", qos: .utility)
    private var cancellation: DirectTelephonyCancellation?
    private var request: UUID?
    private var active = false
    private var expired = false
    private var timer: Timer?
    private let timeout: TimeInterval
    private let collect: (@escaping () -> Bool, @escaping ([[String: Any]]) -> Void) -> Void

    init(timeout: TimeInterval = 12,
         collect: @escaping (@escaping () -> Bool, @escaping ([[String: Any]]) -> Void) -> Void = {
             CSTelephonyProbe.collectWhile($0, update: $1)
         }) {
        self.timeout = timeout; self.collect = collect
    }

    func start() {
        guard !active else { return }
        active = true
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !self.expired else { return }; self.refresh()
        }
        refresh()
    }
    func stop() {
        active = false; cancellation?.cancel(); running = false
        timer?.invalidate(); timer = nil
    }
    func refresh() {
        guard active, request == nil else { return }
        let id = UUID(), token = DirectTelephonyCancellation()
        request = id; cancellation = token; expired = false
        readings = []; running = true; waitingForCall = true; phase = "Чтение состояния…"
        let collect = self.collect
        worker.async { [weak self] in
            collect({ !token.isCancelled }, { raw in
                let values = DirectTelephonyReading.decode(raw)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.request == id, !token.isCancelled else { return }
                    self.readings = values
                }
            })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == id else { return }
                self.request = nil; self.waitingForCall = false; self.running = false
                guard self.active else { return }
                if token.isCancelled {
                    if !self.expired { self.refresh() }
                    return
                }
                self.phase = self.readings.contains { $0.status == .value } ? "Состояние обновлено" : "iOS не вернула показатели"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.active, self.request == id, !token.isCancelled else { return }
            token.cancel(); self.expired = true; self.running = false
            self.phase = "iOS не завершила запрос. Полученные значения сохранены."
        }
    }
    var report: String {
        #if canImport(UIKit)
        let system = "iOS \(UIDevice.current.systemVersion)"
        #else
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        return ["Прямые запросы CoreTelephony", system, phase,
                readings.map(\.reportLine).joined(separator: "\n")].joined(separator: "\n")
    }
    deinit { cancellation?.cancel(); timer?.invalidate() }
}
