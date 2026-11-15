import Foundation
import Darwin
import IDevice

struct PairingAdvertisement {
    let serviceID: String
    let port: Int32
    let txt: [String: Data]
}

struct PairingCandidate {
    let data: Data
    let deviceID: String
}

private final class PINCallback {
    let receive: (String) -> Void
    init(_ receive: @escaping (String) -> Void) { self.receive = receive }
}

/// Owns the sockets on one worker thread. Cancellation only calls shutdown;
/// descriptors are closed by their owner after the FFI has stopped using them.
enum PairingHost {
    static func run(session: PairingSession, ready: @escaping (PairingAdvertisement) -> Void,
                    pin: @escaping (String) -> Void) throws -> PairingCandidate {
        try session.check()
        idevice_set_global_timeout(90)
        var host: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txtBytes: UnsafeMutablePointer<UInt8>?
        var txtCount: UInt = 0
        var hostIRK = [UInt8](repeating: 0, count: 16)
        // A unique name also gives RpPairingFile::generate a fresh host identifier.
        let name = "CarrierSelector-" + UUID().uuidString.prefix(6)
        let prepareError = hostIRK.withUnsafeMutableBufferPointer {
            pairable_host_prepare(name, "Mac17,7", false, &host, &serviceID, &txtBytes, &txtCount, $0.baseAddress)
        }
        defer {
            if let host { pairable_host_free(host) }
            if let serviceID { idevice_string_free(serviceID) }
            if let txtBytes { idevice_data_free(txtBytes, txtCount) }
        }
        try DeviceTransport.check(prepareError, operation: "Создание pairing")
        guard let host, let serviceID, let txtBytes,
              let txt = try PropertyListSerialization.propertyList(from: Data(bytes: txtBytes, count: Int(txtCount)), format: nil) as? [String: String] else {
            throw CarrierError.message("Не удалось подготовить службу сопряжения.")
        }

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CarrierError.message("Не удалось открыть локальное соединение.") }
        defer { Darwin.close(listener) }
        let listenerInterrupt = try session.registerInterrupt { _ = shutdown(listener, SHUT_RDWR) }
        defer { session.unregisterInterrupt(listenerInterrupt) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw CarrierError.message("Не удалось запустить службу сопряжения.") }
        var addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readAddress = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &addressSize) }
        }
        guard readAddress == 0 else { throw CarrierError.message("Не удалось определить порт сопряжения.") }
        try session.check()
        ready(PairingAdvertisement(serviceID: String(cString: serviceID), port: Int32(UInt16(bigEndian: address.sin_port)),
                                   txt: txt.mapValues { Data($0.utf8) }))
        var connected: Int32 = -1
        while connected < 0 {
            try session.check()
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 250)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw CarrierError.message("Служба сопряжения остановилась.") }
            if result == 0 { continue }
            try session.check()
            guard descriptor.revents & Int16(POLLIN) != 0 else { throw CarrierError.message("Локальное соединение было закрыто.") }
            connected = accept(listener, nil, nil)
            if connected < 0 && errno != EINTR { throw CarrierError.message("Не удалось принять соединение от iPhone.") }
        }
        let client = connected
        defer { Darwin.close(client) }
        let clientInterrupt = try session.registerInterrupt { _ = shutdown(client, SHUT_RDWR) }
        defer { session.unregisterInterrupt(clientInterrupt) }
        let callback = PINCallback(pin)
        var pairing: OpaquePointer?
        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        let error = withExtendedLifetime(callback) {
            pairable_host_accept_fd(host, client, { code, context in
                guard let code, let context else { return }
                let text = String(cString: code)
                guard text.count == 6, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
                Unmanaged<PINCallback>.fromOpaque(context).takeUnretainedValue().receive(text)
            }, Unmanaged.passUnretained(callback).toOpaque(), &peer, &pairing)
        }
        defer {
            if let pairing { rp_pairing_file_free(pairing) }
            if let peer { rppairing_peer_device_free(peer) }
        }
        try session.check()
        try DeviceTransport.check(error, operation: "Подтверждение pairing")
        guard let pairing, let peer, let udid = peer.pointee.udid, !String(cString: udid).isEmpty else {
            throw CarrierError.message("Сопряжение не вернуло идентификатор устройства.")
        }
        var bytes: UnsafeMutablePointer<UInt8>?
        var count: UInt = 0
        try DeviceTransport.check(rp_pairing_file_to_bytes(pairing, &bytes, &count), operation: "Подготовка ключей")
        guard let bytes else { throw CarrierError.message("Нет ключей для сохранения.") }
        defer { idevice_data_free(bytes, count) }
        guard var plist = try PropertyListSerialization.propertyList(from: Data(bytes: bytes, count: Int(count)), format: nil) as? [String: Any] else {
            throw CarrierError.message("Некорректный результат сопряжения.")
        }
        // idevice ignores these additional fields when reading its own pairing record.
        // Keep the host identity for future re-advertisement; it must not be regenerated.
        plist["CarrierSelectorHostAltIRK"] = Data(hostIRK)
        plist["CarrierSelectorHostTXT"] = txt
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        return PairingCandidate(data: data, deviceID: String(cString: udid))
    }
}
