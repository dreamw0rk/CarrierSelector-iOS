import UIKit
import CryptoKit
import Combine

enum AppTab: Hashable { case installation, profiles, help }

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var selectedTab: AppTab = .installation
    @Published private(set) var profilesNavigationID = UUID()
    @Published private(set) var installationNavigationID = UUID()
    @Published private(set) var selectedProfile: CarrierProfile?
    @Published private(set) var selectionNotice: String?
    @Published private(set) var verification: ProfileVerification?
    @Published private(set) var connectionFailure: ConnectionFailure?
    @Published private(set) var downloadProgress: DownloadProgress?
    @Published private(set) var downloadRetryAvailable = false
    @Published private(set) var downloadMessage: String?
    @Published private(set) var downloadCanResume = false
    private let resumeStore = CatalogResumeStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("catalog-resume.plist"))
    private var downloader: CatalogDownload?
    private var downloadID: UUID?
    private let draftStore = InstallationDraftStore(defaults: .standard)
    private var draft = InstallationDraft()
    @Published private(set) var verifiedReceipt: InstallReceipt?
    let catalog = CatalogStore()
    let pairing = PairingCoordinator()
    let diagnostics = DiagnosticsModel()
    @Published private(set) var hasPairing = PairingStore.exists
    private let worker = DispatchQueue(label: "dev.carrierselector.transport", qos: .userInitiated)
    @Published private(set) var device: DeviceSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var status = "Подключите свой iPhone"
    @Published private(set) var lastError: String?
    @Published private(set) var receipt: InstallReceipt?
    @Published private(set) var receiptUnreadable = false
    let events = PassthroughSubject<OperationEvent, Never>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @Published private(set) var selectedLineID: String?
    var selectedLine: SIMLine? { device?.lines.first(where: { $0.id == selectedLineID }) }
    private let receiptURL: URL

    private init() {
        let preferences = UserDefaults.standard
        if preferences.object(forKey: "profiles.operatorAutomatic") == nil {
            preferences.set(preferences.object(forKey: "profiles.russianOperator") == nil, forKey: "profiles.operatorAutomatic")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        receiptURL = support.appendingPathComponent("pending-install.json")
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            do { receipt = try JSONDecoder().decode(InstallReceipt.self, from: Data(contentsOf: receiptURL)) }
            catch { receiptUnreadable = true; lastError = "Не удалось прочитать состояние предыдущей установки. Новая отправка заблокирована." }
        }
        if receipt != nil { status = "Ожидается проверка профиля после перезагрузки" }
        downloadCanResume = resumeStore.load(url: CatalogStore.archiveURL, digest: CatalogStore.digest) != nil
        if downloadCanResume { downloadRetryAvailable = true; downloadMessage = "Есть незавершённая загрузка пакетов." }
        draft = draftStore.load()
        selectedProfile = draft.profile(in: catalog.profiles)
        if draft.profilePath != nil && selectedProfile == nil {
            selectionNotice = "Сохранённый профиль больше не найден в каталоге. Выберите другой."
        }
    }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func begin(_ message: String, keepsBackgroundTime: Bool = true) -> Bool {
        guard !busy else { return false }
        busy = true; status = message; lastError = nil; connectionFailure = nil
        downloadRetryAvailable = false
        if keepsBackgroundTime { backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Carrier operation") }
        return true
    }
    private func finish(_ message: String, error: Error? = nil) {
        busy = false; status = message; lastError = error?.localizedDescription
        connectionFailure = error as? ConnectionFailure
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func pairingChanged() {
        device = nil; selectedLineID = nil; verifiedReceipt = nil; verification = nil
        hasPairing = PairingStore.exists
        status = hasPairing ? "Pairing сохранён. Включите LocalDevVPN." : "Создайте или импортируйте Remote Pairing."
        lastError = nil; connectionFailure = nil
    }
    func startAutomaticPairing() {
        guard !receiptUnreadable, begin("Создание pairing на iPhone…", keepsBackgroundTime: false) else { return }
        pairing.start(expectedDeviceHash: receipt?.deviceHash) { [weak self] result in
            guard let self else { return }
            self.hasPairing = PairingStore.exists
            switch result {
            case .success(let snapshot):
                self.adopt(snapshot)
                self.finish("Pairing создан. Можно подключаться.")
            case .failure(let error):
                if error is CancellationError { self.finish("Сопряжение отменено. Сохранённый pairing не изменён.") }
                else { self.finish("Не удалось создать pairing. Сохранённый pairing не изменён.", error: error) }
            }
        }
    }
    private func adopt(_ snapshot: DeviceSnapshot) {
        device = snapshot
        selectionNotice = nil
        if let receipt {
            let lines = snapshot.lines.filter { receipt.matches(device: snapshot, line: $0) }
            selectedLineID = lines.count == 1 ? lines.first?.id : nil
        } else if draft.deviceHash != nil {
            selectedLineID = draft.lineID(on: snapshot)
            if selectedLineID == nil { selectionNotice = "Сохранённая SIM не найдена на этом iPhone. Выберите линию заново." }
        } else {
            selectedLineID = snapshot.lines.first?.id
            saveDraft()
        }
    }
    func selectLine(_ id: String) {
        guard !busy, let device, let line = device.lines.first(where: { $0.id == id }) else { return }
        selectedLineID = line.id
        selectionNotice = nil
        saveDraft()
    }
    private func saveDraft() {
        draft.profilePath = selectedProfile?.path
        draft.profileIdentifier = selectedProfile?.identifier
        draft.profileVersion = selectedProfile?.version
        if let device, let line = selectedLine { draft.select(line: line, device: device) }
        draftStore.save(draft)
    }
    func connect(restartConfirmed: Bool = false) {
        guard begin("Подключение через LocalDevVPN…") else { return }
        verifiedReceipt = nil; verification = nil
        let pending = receipt
        worker.async {
            do {
                let snapshot = try PairingStore.withFile { try DeviceTransport(pairingURL: $0).snapshot() }
                let result = pending.map { ProfileVerification(receipt: $0, device: snapshot, restartConfirmed: restartConfirmed) }
                if result?.confirmed == true { try FileManager.default.removeItem(at: self.receiptURL) }
                DispatchQueue.main.async {
                    self.adopt(snapshot)
                    self.verification = result
                    if result?.confirmed == true {
                        self.receipt = nil
                        self.verifiedReceipt = pending
                        self.selectedProfile = nil
                        self.saveDraft()
                        self.events.send(OperationEvent(title: pending?.targetID ?? "Профиль", detail: pending?.isRestore == true ? "Штатный оператор активен после сброса" : "Активный профиль и версия подтверждены", date: Date(), context: pending.map { OperationContext(receipt: $0, line: result?.active, active: result?.active) }))
                    } else if let result, restartConfirmed {
                        let active = result.active.map { " · активен \($0.bundleID) \($0.version)" } ?? ""
                        self.events.send(OperationEvent(title: pending?.targetID ?? "Проверка", detail: result.title + active, date: Date(), context: pending.map { OperationContext(receipt: $0, line: result.active, active: result.active) }))
                    }
                    self.finish(result?.title ?? "iPhone подключён · данные прочитаны")
                }
            } catch { DispatchQueue.main.async { self.device = nil; self.finish("Не удалось подключиться", error: error) } }
        }
    }
    func downloadCatalog() {
        guard begin("Загрузка пакетов…") else { return }
        let id = UUID()
        downloadID = id; downloadProgress = DownloadProgress(); downloadRetryAvailable = false; downloadMessage = nil
        let catalog = self.catalog
        let resumeStore = self.resumeStore
        let resumeData = resumeStore.load(url: CatalogStore.archiveURL, digest: CatalogStore.digest)
        let download = CatalogDownload(accept: { try catalog.acceptDownload($0) }, progress: { [weak self] progress in
            DispatchQueue.main.async {
                guard let self, self.downloadID == id, self.downloadProgress?.phase != .cancelling else { return }
                self.downloadProgress = progress
                self.status = progress.phase == .validating ? "Проверка загруженных пакетов…" : "Загрузка пакетов…"
            }
        }, resumeDataReceived: { data in
            resumeStore.save(data, url: CatalogStore.archiveURL, digest: CatalogStore.digest)
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.downloadID == id else { return }
                self.downloadID = nil; self.downloader = nil; self.downloadProgress = nil
                self.downloadCanResume = resumeStore.load(url: CatalogStore.archiveURL, digest: CatalogStore.digest) != nil
                switch result {
                case .success: self.finish("Пакеты загружены")
                case .failure(let error):
                    self.downloadRetryAvailable = true
                    self.downloadMessage = error is CancellationError ? (self.downloadCanResume ? "Загрузка приостановлена." : "Загрузка остановлена. Продолжение недоступно.") : "Пакеты не загружены. " + error.localizedDescription
                    if error is CancellationError { self.finish(self.downloadCanResume ? "Загрузка приостановлена" : "Загрузка остановлена") }
                    else { self.finish("Не удалось загрузить пакеты", error: error) }
                }
            }
        })
        downloader = download
        download.start(url: CatalogStore.archiveURL, resumeData: resumeData)
    }
    func restartCatalogDownload() {
        guard !busy else { return }
        resumeStore.clear(); downloadCanResume = false
        downloadCatalog()
    }
    func cancelCatalogDownload() {
        guard downloader?.cancel() == true else { return }
        downloadProgress?.phase = .cancelling
        status = "Остановка загрузки…"
    }
    func startDiagnostics(mode: DiagnosticMode = .registration) {
        guard hasPairing, begin("Подключение диагностики…", keepsBackgroundTime: false) else { return }
        let token = diagnostics.begin(mode: mode)
        let expectedUDID = device?.udid
        worker.async {
            var latest: [String: DiagnosticReading] = [:]
            var stats = DiagnosticStreamStats()
            var lastDelivery = DispatchTime.now().uptimeNanoseconds
            var failure: Error?
            let collector = DiagnosticCollector()
            var deadline: Date?
            var retry = DiagnosticReconnectPolicy()
            var connectedUDID = expectedUDID
            do {
                try PairingStore.withFile { pairing in
                    while !token.isStopped {
                        do {
                            if let deadline, Date() >= deadline { token.stop(); break }
                            let transport = try DeviceTransport(pairingURL: pairing)
                            if token.isStopped { break }
                            let snapshot = try transport.snapshot()
                            if let connectedUDID, snapshot.udid != connectedUDID {
                                failure = CarrierError.message("Подключён другой iPhone. Прочитайте устройство заново."); break
                            }
                            connectedUDID = snapshot.udid
                            if token.isStopped { break }
                            DispatchQueue.main.async { self.diagnostics.attached(snapshot, token: token) }
                            let duration = deadline.map { max(0, $0.timeIntervalSinceNow) } ?? 90
                            try transport.diagnose(session: token, collector: collector, duration: duration, ready: {
                                if deadline == nil { deadline = Date().addingTimeInterval(90) }
                                retry.recovered()
                                DispatchQueue.main.async { self.diagnostics.collecting(token: token) }
                            }, receive: { values, received in
                                for value in values where latest[value.id].map({ $0.date <= value.date }) ?? true { latest[value.id] = value }
                                stats = received
                                let now = DispatchTime.now().uptimeNanoseconds
                                if now - lastDelivery > 250_000_000 {
                                    let batch = Array(latest.values), capturedStats = stats
                                    DispatchQueue.main.async { self.diagnostics.update(batch, stats: capturedStats, token: token) }
                                    lastDelivery = now
                                }
                            })
                            break
                        } catch {
                            if token.isStopped { break }
                            guard retry.shouldRetry(at: Date(), deadline: deadline) else { failure = error; break }
                            collector.beginReconnect(); stats = collector.stats
                            DispatchQueue.main.async { self.diagnostics.reconnecting(token: token) }
                            Thread.sleep(forTimeInterval: 1)
                        }
                    }
                }
            } catch { if !token.isStopped { failure = error } }
            let batch = Array(latest.values), capturedStats = stats, capturedError = failure
            DispatchQueue.main.async {
                self.diagnostics.update(batch, stats: capturedStats, token: token)
                self.diagnostics.finish(token: token, error: capturedError)
                self.finish(capturedError == nil ? "Диагностика завершена" : "Диагностика недоступна", error: capturedError)
            }
        }
    }
    func install(_ profile: CarrierProfile, line: SIMLine) {
        guard let expectedDevice = device, receipt == nil, !receiptUnreadable, begin("Проверка пакета и выбранной SIM…") else { return }
        verifiedReceipt = nil; verification = nil
        let recordURL = receiptURL
        worker.async {
            var pending: InstallReceipt?
            do {
                try PairingStore.withFile { pairing in
                    let connection = try DeviceTransport(pairingURL: pairing)
                    let current = try connection.snapshot()
                    guard self.catalog.supports(current) else { throw CarrierError.message("Эта модель или плата iPhone отсутствует в каталоге исходного проекта.") }
                    guard current.udid == expectedDevice.udid,
                          let actualLine = current.lines.first(where: { $0.id == line.id }),
                          actualLine.imsi == line.imsi, actualLine.iccid == line.iccid,
                          current.lines.filter({ $0.selector == line.selector }).count == 1,
                          let selector = actualLine.selector else { throw CarrierError.message("Устройство или SIM изменились. Заново прочитайте данные.") }
                    guard profile.compatibility(hardware: current.hardware, product: current.product) != 50 else {
                        throw CarrierError.message("В профиле нет настроек для платы этого iPhone.")
                    }
                    guard actualLine.bundleID.hasPrefix("com.apple."), !actualLine.version.isEmpty else {
                        throw CarrierError.message("Не удалось определить активный операторский профиль. Отправка отменена.")
                    }
                    guard actualLine.bundleID != profile.identifier || actualLine.version != profile.version else {
                        throw CarrierError.message("Этот профиль уже активен на выбранной SIM.")
                    }
                    if actualLine.bundleID == profile.identifier,
                       profile.version.compare(actualLine.version, options: .numeric) == .orderedAscending {
                        throw CarrierError.message("Установка более старой версии того же профиля заблокирована. Сначала вернитесь к штатному профилю на вкладке «Установка».")
                    }
                    let files = try self.catalog.files(for: profile)
                    try connection.install(files: files, selector: selector) {
                        let record = InstallReceipt(deviceHash: Self.hash(current.udid), selectorHash: Self.hash(selector),
                                                    targetID: profile.identifier, targetVersion: profile.version,
                                                    previousID: actualLine.bundleID, previousVersion: actualLine.version, date: Date())
                        try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try JSONEncoder().encode(record).write(to: recordURL, options: [.atomic, .completeFileProtection])
                        pending = record
                    }
                }
                let sent = pending
                DispatchQueue.main.async {
                    self.receipt = sent
                    self.finish("Профиль отправлен. Перезагрузите iPhone, включите LocalDevVPN и нажмите «Проверить установку».")
                    self.events.send(OperationEvent(title: profile.name, detail: "Отправлен · ожидается проверка после перезагрузки", date: Date(), context: sent.map { OperationContext(receipt: $0, line: line) }))
                }
            } catch {
                let uncertain = pending
                DispatchQueue.main.async {
                    self.receipt = uncertain
                    self.finish(uncertain == nil ? "Установка не началась" : "Результат отправки не подтверждён. Автоповтор отключён. Перезагрузите iPhone и проверьте профиль.", error: error)
                    self.events.send(OperationEvent(title: profile.name, detail: uncertain == nil ? "Не отправлен" : "Результат отправки неизвестен", date: Date(), context: uncertain.map { OperationContext(receipt: $0, line: line) } ?? OperationContext(device: expectedDevice, line: line, target: profile)))
                }
            }
        }
    }
    func showProfiles() {
        profilesNavigationID = UUID()
        selectedTab = .profiles
    }
    func showInstallation() {
        installationNavigationID = UUID()
        selectedTab = .installation
    }
    func choose(_ profile: CarrierProfile) {
        selectedProfile = profile
        verifiedReceipt = nil
        saveDraft()
        showInstallation()
    }
    var installationBlocker: String? {
        guard !receiptUnreadable else { return "Не удалось прочитать предыдущую операцию. Новая установка заблокирована." }
        guard receipt == nil else { return "Сначала проверьте предыдущую установку после перезагрузки." }
        guard let device else { return "Подключите iPhone, чтобы выбрать SIM." }
        guard catalog.supports(device) else { return "Для этой модели iPhone нет пакетов в каталоге." }
        guard let line = selectedLine, line.selector != nil else { return "Не удалось прочитать данные SIM. Обновите подключение." }
        guard let profile = selectedProfile else { return "Выберите профиль из каталога." }
        guard profile.compatibility(hardware: device.hardware, product: device.product) != 50 else { return "Выберите другой профиль: этот не подходит модели iPhone." }
        guard profile.identifier != line.bundleID || profile.version != line.version else { return "Этот профиль уже активен на выбранной SIM." }
        if profile.identifier == line.bundleID && profile.version.compare(line.version, options: .numeric) == .orderedAscending {
            return "Сначала вернитесь к штатному профилю, чтобы установить более старую версию."
        }
        guard catalog.isDownloaded else { return "Загрузите пакеты для установки · около 170 МБ." }
        return nil
    }
    var inferredOperator: RussianOperator? {
        guard selectedLine?.mcc == "250" else { return nil }
        return RussianOperator.inferred(nativeIdentifier: stockProfile?.identifier)
    }
    var stockProfile: CarrierProfile? {
        guard let device, let line = selectedLine else { return nil }
        return catalog.stockProfile(for: line, device: device)
    }
    var canRestoreStock: Bool {
        guard !busy, !receiptUnreadable, catalog.isDownloaded, let device,
              let line = selectedLine, line.selector != nil, stockProfile != nil else { return false }
        guard let receipt else { return true }
        return !receipt.isRestore && receipt.matches(device: device, line: line)
    }
    func restoreStock() {
        guard canRestoreStock, let expectedDevice = device, let expectedLine = selectedLine,
              let expectedProfile = stockProfile, begin("Подготовка возврата к штатному профилю…") else { return }
        verifiedReceipt = nil; verification = nil
        let previousReceipt = receipt
        worker.async {
            var pending: InstallReceipt?
            do {
                try PairingStore.withFile { pairing in
                    let connection = try DeviceTransport(pairingURL: pairing)
                    let current = try connection.snapshot()
                    guard current.udid == expectedDevice.udid,
                          let actual = current.lines.first(where: { $0.id == expectedLine.id }),
                          actual.imsi == expectedLine.imsi, actual.iccid == expectedLine.iccid,
                          let selector = actual.selector,
                          current.lines.filter({ $0.selector == selector }).count == 1,
                          self.catalog.supports(current),
                          let native = self.catalog.stockProfile(for: actual, device: current),
                          native.path == expectedProfile.path else {
                        throw CarrierError.message("Устройство, SIM или её штатный оператор изменились. Прочитайте данные заново.")
                    }
                    if let previousReceipt, !previousReceipt.matches(device: current, line: actual) || previousReceipt.isRestore {
                        throw CarrierError.message("Сначала завершите проверку предыдущей операции на её SIM.")
                    }
                    let source = try self.catalog.files(for: native)
                    let files = try StockReset.files(from: source, expectedIdentifier: native.identifier)
                    try connection.install(files: files, selector: selector) {
                        let record = InstallReceipt(deviceHash: Self.hash(current.udid), selectorHash: Self.hash(selector),
                            targetID: native.identifier, targetVersion: "", previousID: actual.bundleID,
                            previousVersion: actual.version, date: Date(), operation: "restoreStock")
                        try FileManager.default.createDirectory(at: self.receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try JSONEncoder().encode(record).write(to: self.receiptURL, options: [.atomic, .completeFileProtection])
                        pending = record
                    }
                }
                let sent = pending
                DispatchQueue.main.async {
                    self.receipt = sent
                    self.finish("Пакет сброса отправлен. Перезагрузите iPhone, включите LocalDevVPN и проверьте профиль.")
                    self.events.send(OperationEvent(title: "Возврат к штатному профилю", detail: "Отправлен для выбранной SIM · ожидается перезагрузка и проверка", date: Date(), context: sent.map { OperationContext(receipt: $0, line: expectedLine) }))
                }
            } catch {
                let uncertain = pending
                DispatchQueue.main.async {
                    self.receipt = uncertain ?? previousReceipt
                    self.finish(uncertain == nil ? "Сброс не начался" : "Результат сброса неизвестен. Повтор отключён; перезагрузите iPhone и проверьте профиль.", error: error)
                    self.events.send(OperationEvent(title: "Возврат к штатному профилю", detail: uncertain == nil ? "Не отправлен" : "Ответ неизвестен · требуется проверка", date: Date(), context: uncertain.map { OperationContext(receipt: $0, line: expectedLine) } ?? OperationContext(device: expectedDevice, line: expectedLine, target: expectedProfile, restore: true)))
                }
            }
        }
    }

}
