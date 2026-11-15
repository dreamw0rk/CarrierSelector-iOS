import Foundation
import IDevice
import Darwin

/// All FFI calls run on AppModel's serial worker, never on the UI thread.
final class DeviceTransport {
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var lockdown: OpaquePointer?

    init(pairingURL: URL) throws {
        idevice_set_global_timeout(30)
        var pairing: OpaquePointer?
        try Self.check(rp_pairing_file_read(pairingURL.path, &pairing), operation: "Pairing-файл")
        defer { if let pairing { rp_pairing_file_free(pairing) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(49152).bigEndian
        inet_pton(AF_INET, "10.7.0.1", &address.sin_addr)
        do {
            let error = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socket in
                    tunnel_create_rppairing(socket, socklen_t(MemoryLayout<sockaddr_in>.size),
                                           "CarrierSelector", pairing, nil, nil, &adapter, &handshake)
                }
            }
            try Self.check(error, operation: "Туннель LocalDevVPN")
            try Self.check(lockdownd_connect_rsd(adapter, handshake, &lockdown), operation: "Lockdown")
        } catch { close(); throw error }
    }

    deinit { close() }
    private func close() {
        if let lockdown { lockdownd_client_free(lockdown) }; lockdown = nil
        if let handshake { rsd_handshake_free(handshake) }; handshake = nil
        if let adapter { adapter_free(adapter) }; adapter = nil
    }

    static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, operation: String) throws {
        guard let error else { return }
        defer { idevice_error_free(error) }
        // Service errors can include a SIM-specific staging path. Never display that path.
        throw ConnectionFailure.ffi(operation: operation, code: error.pointee.code, subcode: error.pointee.sub_code)
    }

    private func value(_ key: String? = nil) throws -> Any {
        var node: UnsafeMutableRawPointer?
        let error = key.map { lockdownd_get_value(lockdown, $0, nil, &node) }
            ?? lockdownd_get_value(lockdown, nil, nil, &node)
        try Self.check(error, operation: "Чтение устройства")
        guard let node else { throw CarrierError.message("Пустой ответ Lockdown.") }
        defer { plist_free(node) }
        var xml: UnsafeMutablePointer<CChar>?
        var size: UInt32 = 0
        _ = plist_to_xml(node, &xml, &size)
        guard let xml else { throw CarrierError.message("Не удалось прочитать ответ устройства.") }
        defer { plist_mem_free(xml) }
        return try PropertyListSerialization.propertyList(from: Data(bytes: xml, count: Int(size)), format: nil)
    }

    func snapshot() throws -> DeviceSnapshot {
        guard var values = try value() as? [String: Any] else { throw CarrierError.message("Некорректный ответ iPhone.") }
        values["CarrierBundleInfoArray"] = try value("CarrierBundleInfoArray")
        for key in ["InternationalMobileSubscriberIdentity", "IntegratedCircuitCardIdentity", "IntegratedCircuitCardIdentifier"] {
            for suffix in ["", "2"] where values[key + suffix] == nil {
                values[key + suffix] = try? value(key + suffix)
            }
        }
        return try DeviceSnapshot.parse(values)
    }

    /// Read-only, exclusive use of this transport. Only this connection's adapter is closed on stop.
    func diagnose(session: DiagnosticSession, collector: DiagnosticCollector, duration: TimeInterval, ready: () -> Void,
                  receive: ([DiagnosticReading], DiagnosticStreamStats) -> Void) throws {
        if session.isStopped { return }
        var client: OpaquePointer?
        try Self.check(os_trace_relay_connect_rsd(adapter, handshake, &client), operation: "Подключение диагностики")
        guard let connected = client, let adapter else { throw CarrierError.message("Служба журнала недоступна на этом iPhone.") }
        defer { if let client { os_trace_relay_free(client) } }
        // No FFI operation below borrows adapter itself: trace owns a separate stream.
        session.arm {
            if let error = adapter_close(adapter) { idevice_error_free(error) }
        }
        defer { session.disarm() }
        var receiver: OpaquePointer?
        client = nil // start_trace consumes its client on both success and failure.
        try Self.check(os_trace_relay_start_trace(connected, &receiver, nil), operation: "Запуск журнала")
        guard let receiver else { throw CarrierError.message("iPhone не вернул поток журнала.") }
        defer { os_trace_relay_receiver_free(receiver) }
        if session.isStopped { return }
        ready()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, duration)) { session.stop() }
        while !session.isStopped {
            var entry: UnsafeMutablePointer<OsTraceLog>?
            let error = os_trace_relay_next(receiver, &entry)
            defer { if let entry { os_trace_relay_free_log(entry) } }
            if session.isStopped {
                if let error { idevice_error_free(error) }
                break
            }
            try Self.check(error, operation: "Чтение журнала")
            guard let entry else { continue }
            let process = entry.pointee.filename.map { String(cString: $0) } ?? ""
            let category = entry.pointee.label?.pointee.category.map { String(cString: $0) } ?? ""
            let message = (process as NSString).lastPathComponent == "CommCenter"
                ? entry.pointee.message.map { String(cString: $0) } ?? "" : ""
            let readings = collector.ingest(process: process, category: category, message: message,
                                             timestamp: entry.pointee.timestamp, receivedAt: Date())
            receive(readings, collector.stats)
        }
    }

    func install(files: [(String, Data)], selector: String, beforeDispatch: () throws -> Void) throws {
        var afc: OpaquePointer?
        try Self.check(afc_client_connect_rsd(adapter, handshake, &afc), operation: "AFC")
        defer { if let afc { afc_client_free(afc) } }
        var installer: OpaquePointer?
        try Self.check(installation_proxy_connect_rsd(adapter, handshake, &installer), operation: "Installation Proxy")
        defer { if let installer { installation_proxy_client_free(installer) } }

        let staging = "/PublicStaging/CarrierSelector-\(UUID().uuidString).ipcc"
        // PublicStaging may already exist. Only this shared parent tolerates an EEXIST.
        if let error = afc_make_directory(afc, "/PublicStaging") { idevice_error_free(error) }
        try Self.check(afc_make_directory(afc, staging), operation: "Подготовка пакета")
        defer {
            if let error = afc_remove_path_and_contents(afc, staging) { idevice_error_free(error) }
        }
        let root = staging + "/Payload/" + selector
        var directories = Set<String>()
        func mkdir(_ path: String) throws {
            guard path != staging, !directories.contains(path) else { return }
            try mkdir((path as NSString).deletingLastPathComponent)
            try Self.check(afc_make_directory(afc, path), operation: "Подготовка каталогов")
            directories.insert(path)
        }
        try mkdir(root)
        for (relative, data) in files {
            let destination = root + "/" + relative
            try mkdir((destination as NSString).deletingLastPathComponent)
            var file: OpaquePointer?
            try Self.check(afc_file_open(afc, destination, AfcWrOnly, &file), operation: "Передача профиля")
            do {
                try data.withUnsafeBytes { buffer in
                    try Self.check(afc_file_write(file, buffer.bindMemory(to: UInt8.self).baseAddress, data.count), operation: "Передача профиля")
                }
            } catch {
                if let error = afc_file_close(file) { idevice_error_free(error) }
                throw error
            }
            try Self.check(afc_file_close(file), operation: "Завершение передачи")
        }
        let optionsXML = try PropertyListSerialization.data(fromPropertyList: ["PackageType": "CarrierBundle"], format: .xml, options: 0)
        var options: UnsafeMutableRawPointer?
        optionsXML.withUnsafeBytes { bytes in
            _ = plist_from_xml(bytes.bindMemory(to: CChar.self).baseAddress, UInt32(optionsXML.count), &options)
        }
        guard let options else { throw CarrierError.message("Не удалось подготовить параметры IPCC.") }
        defer { plist_free(options) }
        try beforeDispatch()
        // Deliberately one attempt. A lost response is not proof of failure.
        try Self.check(installation_proxy_install(installer, staging, options), operation: "Отправка IPCC")
    }
}
