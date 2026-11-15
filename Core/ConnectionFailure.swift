import Foundation

/// Numeric categories come from the pinned idevice FFI. Raw error messages can contain SIM paths.
struct ConnectionFailure: LocalizedError {
    enum Reason: Equatable { case missingPairing, locked, invalidPairing, keychain, developerMode, transport, timeout, secureConnection, service }
    let reason: Reason
    var operation: String? = nil
    var code: Int32? = nil
    var subcode: Int32? = nil
    var title: String {
        switch reason {
        case .missingPairing: return "Нужен ключ подключения"
        case .locked: return "Разблокируйте iPhone"
        case .invalidPairing: return "Не удалось использовать pairing"
        case .keychain: return "Ключ подключения недоступен"
        case .developerMode: return "Нужен режим разработчика"
        case .transport: return "Нет соединения с iPhone"
        case .timeout: return "iPhone не ответил вовремя"
        case .secureConnection: return "Защищённое соединение не установлено"
        case .service: return "Операция не выполнена"
        }
    }
    var errorDescription: String? {
        switch reason {
        case .missingPairing: return "Откройте настройки подключения и создайте или импортируйте Remote Pairing этого iPhone."
        case .locked: return "Разблокируйте устройство и повторите подключение."
        case .invalidPairing: return "Откройте настройки подключения и создайте ключ заново или импортируйте Remote Pairing именно этого iPhone."
        case .keychain: return "Разблокируйте iPhone и повторите попытку. Если ошибка сохраняется, откройте настройки подключения."
        case .developerMode: return "Включите режим разработчика в Настройках → Конфиденциальность и безопасность, затем повторите подключение."
        case .transport, .timeout: return "Проверьте Wi-Fi и LocalDevVPN, доступ приложения к локальной сети и повторите подключение."
        case .secureConnection: return "Повторите подключение с включённым LocalDevVPN. Если ошибка сохраняется, проверьте pairing в настройках подключения."
        case .service: return "Повторно прочитайте данные iPhone. Если профиль уже отправлен, сначала проверьте результат после перезагрузки."
        }
    }
    var needsPairing: Bool { reason == .missingPairing || reason == .invalidPairing || reason == .keychain }
    var technical: String? {
        guard let code else { return nil }
        return "\(operation ?? "Подключение") · \(code)/\(subcode ?? 0)"
    }
    static func ffi(operation: String, code: Int32, subcode: Int32) -> Self {
        let reason: Reason
        switch code {
        case 23, 32: reason = .locked
        case 18: reason = .invalidPairing
        case 103 where [3, 5, 6].contains(subcode): reason = .invalidPairing
        case 24: reason = .developerMode
        case 109: reason = .timeout
        case 1, 19: reason = .transport
        case 2, 3, 4: reason = .secureConnection
        default: reason = .service
        }
        return Self(reason: reason, operation: operation, code: code, subcode: subcode)
    }
}
