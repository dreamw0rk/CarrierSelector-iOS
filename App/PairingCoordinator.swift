import Foundation
import Combine

/// Published state and Bonjour are confined to the main queue; the blocking FFI
/// and connection verification run on one worker. A run ID rejects stale callbacks.
final class PairingCoordinator: NSObject, ObservableObject, NetServiceDelegate {
    @Published private(set) var running = false
    @Published private(set) var phase = ""
    @Published private(set) var pin: String?
    @Published private(set) var hostName = "CarrierSelector"
    @Published private(set) var backgroundNotice: String?
    private let worker = DispatchQueue(label: "dev.carrierselector.pairing", qos: .userInitiated)
    private var runID: UUID?
    private var session: PairingSession?
    private var service: NetService?
    private var workerStarted = false
    private var stopError: Error?
    private var completion: ((Result<DeviceSnapshot, Error>) -> Void)?

    func start(expectedDeviceHash: String?, completion: @escaping (Result<DeviceSnapshot, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running else { return }
        guard PairingSupport.canCreate(onMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) else {
            completion(.failure(CarrierError.message("Создание pairing на устройстве доступно с iOS 27. На iOS 26 импортируйте Remote Pairing, созданный на компьютере.")))
            return
        }
        let id = UUID(), session = PairingSession()
        self.runID = id; self.session = session; self.completion = completion
        running = true; phase = "Подготовка сопряжения…"; pin = nil; stopError = nil
        backgroundNotice = nil; workerStarted = false
        PairingBackground.shared.begin(expiration: { [weak self] in
            self?.cancel(error: CarrierError.message("iOS остановила фоновое сопряжение. Вернитесь в приложение и начните снова."))
        }, launch: { [weak self] in
            guard let self, self.runID == id else { return }
            self.workerStarted = true
            self.worker.async { [weak self] in
                do {
                    let candidate = try PairingHost.run(session: session, ready: { [weak self] advertisement in
                        DispatchQueue.main.async { [weak self] in self?.advertise(advertisement, id: id) }
                    }, pin: { [weak self] code in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.runID == id, (try? session.check()) != nil else { return }
                            self.pin = code
                            self.phase = "Введите код в системном окне сопряжения"
                            PairingBackground.shared.progress(2, subtitle: "Код \(code) · введите в Настройках")
                        }
                    })
                    try session.check()
                    try PairingRecord.validate(candidate.data)
                    if let expectedDeviceHash, AppModel.hash(candidate.deviceID) != expectedDeviceHash {
                        throw CarrierError.message("Есть незавершённая установка на другом устройстве. Его pairing не будет заменён.")
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.runID == id, (try? session.check()) != nil else { return }
                        self.service?.stop(); self.service = nil
                        self.pin = nil; self.phase = "Проверка соединения с этим iPhone…"
                        PairingBackground.shared.progress(3, subtitle: "Проверка LocalDevVPN")
                    }
                    let snapshot = try PairingStore.withFile(data: candidate.data) { url in
                        try session.check()
                        return try DeviceTransport(pairingURL: url).snapshot()
                    }
                    guard snapshot.udid == candidate.deviceID else {
                        throw CarrierError.message("Сопряжённое устройство не совпадает с iPhone за LocalDevVPN. Старый pairing сохранён.")
                    }
                    try session.commit { try PairingStore.save(candidate.data) }
                    DispatchQueue.main.async { [weak self] in self?.finish(.success(snapshot), id: id) }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.finish(.failure(self.stopError ?? error), id: id)
                    }
                }
            }
        }, fallback: { [weak self] in
            self?.backgroundNotice = "Длительная фоновая задача недоступна. Если iOS остановит ожидание в Настройках, вернитесь и повторите сопряжение."
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self, self.runID == id else { return }
            self.cancel(error: CarrierError.message("Время сопряжения истекло. Начните снова, чтобы получить новый код."))
        }
    }
    func cancel(error: Error = CancellationError()) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let id = runID, let session, session.cancel() else { return }
        stopError = error
        phase = "Остановка сопряжения…"; pin = nil
        service?.stop(); service = nil
        PairingBackground.shared.end(success: false)
        if !workerStarted { finish(.failure(error), id: id) }
    }
    private func advertise(_ advertisement: PairingAdvertisement, id: UUID) {
        guard runID == id, let session, (try? session.check()) != nil else { return }
        hostName = advertisement.txt["name"].flatMap { String(data: $0, encoding: .utf8) } ?? "CarrierSelector"
        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: advertisement.serviceID, port: advertisement.port)
        service.delegate = self
        guard service.setTXTRecord(NetService.data(fromTXTRecord: advertisement.txt)) else {
            cancel(error: CarrierError.message("Не удалось объявить службу сопряжения.")); return
        }
        self.service = service
        phase = "Публикация службы сопряжения…"
        service.publish(options: .noAutoRename)
    }
    func netServiceDidPublish(_ sender: NetService) {
        guard sender === service, running else { return }
        phase = "Откройте Настройки → Конфиденциальность и безопасность → Режим разработчика → \(hostName)"
        PairingBackground.shared.progress(1, subtitle: "Выберите \(hostName) в Режиме разработчика")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        cancel(error: CarrierError.message("Служба сопряжения недоступна. Проверьте разрешение «Локальная сеть» для CarrierSelector и подключение к Wi-Fi."))
    }
    private func finish(_ result: Result<DeviceSnapshot, Error>, id: UUID) {
        guard runID == id else { return }
        service?.stop(); service = nil
        let success: Bool
        if case .success = result { success = true } else { success = false }
        PairingBackground.shared.end(success: success)
        running = false; pin = nil; runID = nil; session = nil
        phase = success ? "Pairing сохранён и проверен" : "Сопряжение остановлено"
        let callback = completion
        completion = nil
        callback?(result)
    }
}
