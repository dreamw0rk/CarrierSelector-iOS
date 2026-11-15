import Foundation

struct ProfileVerification {
    enum Outcome: Equatable {
        case restartRequired, wrongDevice, simMissing, ambiguousSIM, unreadableProfile
        case differentProfile, differentVersion, verified
    }
    let outcome: Outcome
    let active: SIMLine?
    let checkedAt: Date
    var confirmed: Bool { outcome == .verified }
    var title: String {
        switch outcome {
        case .restartRequired: return "Нужна проверка после перезагрузки"
        case .wrongDevice: return "Подключён другой iPhone"
        case .simMissing: return "Нужная SIM не найдена"
        case .ambiguousSIM: return "Не удалось определить SIM"
        case .unreadableProfile: return "Активный профиль не прочитан"
        case .differentProfile: return "Активен другой профиль"
        case .differentVersion: return "Версия профиля отличается"
        case .verified: return "Профиль подтверждён"
        }
    }
    var guidance: String {
        switch outcome {
        case .restartRequired: return "Перезагрузите iPhone, включите LocalDevVPN и нажмите «Проверить установку»."
        case .wrongDevice: return "Восстановите подключение к iPhone, на который отправлялся профиль."
        case .simMissing, .ambiguousSIM: return "Включите исходную SIM в настройках сотовой связи и прочитайте данные ещё раз."
        case .unreadableProfile: return "iOS не вернула корректные данные пакета. Повторите проверку."
        case .differentProfile: return "Ожидаемый пакет не активен. Можно повторить проверку или вернуться к штатному профилю, если сброс доступен."
        case .differentVersion: return "Операторский пакет совпадает, но его версия отличается от отправленной. Установка пока не подтверждена."
        case .verified: return "Активный пакет совпадает с ожидаемым. Звонки и интернет проверяются отдельно."
        }
    }
    init(receipt: InstallReceipt, device: DeviceSnapshot, restartConfirmed: Bool, date: Date = Date()) {
        checkedAt = date
        guard InstallReceipt.hash(device.udid) == receipt.deviceHash else { outcome = .wrongDevice; active = nil; return }
        let lines = device.lines.filter { receipt.matches(device: device, line: $0) }
        guard lines.count == 1, let line = lines.first else {
            outcome = lines.isEmpty ? .simMissing : .ambiguousSIM; active = nil; return
        }
        active = line
        guard restartConfirmed else { outcome = .restartRequired; return }
        guard line.bundleID.hasPrefix("com.apple."), line.version != "0",
              line.version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil else {
            outcome = .unreadableProfile; return
        }
        guard line.bundleID == receipt.targetID else { outcome = .differentProfile; return }
        outcome = receipt.isRestore || line.version == receipt.targetVersion ? .verified : .differentVersion
    }
}
