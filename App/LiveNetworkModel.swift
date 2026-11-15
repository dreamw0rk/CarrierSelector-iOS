import UIKit
import Combine
import CoreTelephony
import Network

/// Public iOS information. It does not depend on pairing or on debug log messages.
final class LiveNetworkModel: ObservableObject {
    @Published private(set) var radio = RadioSnapshot.make(services: [:], dataService: nil)
    @Published private(set) var route = "Определяется…"
    @Published private(set) var updated: Date?
    private let telephony = CTTelephonyNetworkInfo()
    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0

    func start() {
        guard monitor == nil else { refresh(); return }
        generation += 1
        let current = generation
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let route: String
            if path.status != .satisfied { route = "Нет доступного маршрута" }
            else if path.usesInterfaceType(.wifi) { route = "Wi-Fi" }
            else if path.usesInterfaceType(.cellular) { route = "Сотовая сеть" }
            else if path.usesInterfaceType(.wiredEthernet) { route = "Ethernet" }
            else { route = "VPN / другое подключение" }
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.monitor != nil else { return }
                self.route = route
            }
        }
        monitor.start(queue: DispatchQueue(label: "CarrierSelector.network-path"))
        for name in [NSNotification.Name.CTServiceRadioAccessTechnologyDidChange, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func refresh() {
        radio = RadioSnapshot.make(services: telephony.serviceCurrentRadioAccessTechnology ?? [:], dataService: telephony.dataServiceIdentifier)
        updated = Date()
    }
    func stop() {
        generation += 1
        monitor?.cancel(); monitor = nil
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }
    deinit {
        monitor?.cancel(); timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
