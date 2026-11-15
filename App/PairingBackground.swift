import UIKit
import BackgroundTasks

/// The system-provided Live Activity keeps pairing and its PIN visible in Settings.
final class PairingBackground {
    static let shared = PairingBackground()
    private var registered = false
    private var task: BGContinuedProcessingTask?
    private var requestID: String?
    private var onLaunch: (() -> Void)?
    private var onExpiration: (() -> Void)?
    private var shortTask: UIBackgroundTaskIdentifier = .invalid
    private var prefix: String { (Bundle.main.bundleIdentifier ?? "dev.carrierselector.ios") + ".pairing." }

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + "*", using: .main) { [weak self] incoming in
            guard let self, let task = incoming as? BGContinuedProcessingTask, incoming.identifier == self.requestID else {
                incoming.setTaskCompleted(success: false); return
            }
            self.task = task
            task.progress.totalUnitCount = 4
            task.progress.completedUnitCount = 0
            task.expirationHandler = { [weak self] in
                DispatchQueue.main.async { self?.onExpiration?(); self?.end(success: false) }
            }
            let launch = self.onLaunch
            self.onLaunch = nil
            launch?()
        }
    }

    func begin(expiration: @escaping () -> Void, launch: @escaping () -> Void, fallback: () -> Void) {
        onExpiration = expiration
        if registered {
            let id = prefix + UUID().uuidString
            requestID = id
            onLaunch = launch
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Сопряжение CarrierSelector", subtitle: "Подготовка")
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                // Some systems accept a request but never deliver its launch callback.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.requestID == id, self.onLaunch != nil else { return }
                    self.onExpiration?(); self.end(success: false)
                }
                return
            } catch { requestID = nil; onLaunch = nil }
        }
        fallback()
        shortTask = UIApplication.shared.beginBackgroundTask(withName: "Pairing") { [weak self] in
            DispatchQueue.main.async { self?.onExpiration?(); self?.end(success: false) }
        }
        launch()
    }
    func progress(_ completed: Int64, subtitle: String) {
        task?.progress.completedUnitCount = completed
        task?.updateTitle("Сопряжение CarrierSelector", subtitle: subtitle)
    }
    func end(success: Bool) {
        if let task {
            if success { task.progress.completedUnitCount = 4 }
            task.updateTitle("Сопряжение CarrierSelector", subtitle: success ? "Pairing сохранён" : "Сопряжение остановлено")
            task.setTaskCompleted(success: success)
        }
        task = nil
        if let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID) }
        requestID = nil; onLaunch = nil; onExpiration = nil
        if shortTask != .invalid { UIApplication.shared.endBackgroundTask(shortTask); shortTask = .invalid }
    }
}

final class LifecycleDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        PairingBackground.shared.register()
        return true
    }
}
