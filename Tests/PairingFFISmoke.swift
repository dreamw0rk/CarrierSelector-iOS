import Foundation
import IDevice

@main
struct PairingFFISmoke {
    static func main() throws {
        var host: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var bytes: UnsafeMutablePointer<UInt8>?
        var count: UInt = 0
        var irk = [UInt8](repeating: 0, count: 16)
        let error = irk.withUnsafeMutableBufferPointer {
            pairable_host_prepare("CarrierSelector-test-" + UUID().uuidString, "Mac17,7", false,
                                  &host, &serviceID, &bytes, &count, $0.baseAddress)
        }
        defer {
            if let error { idevice_error_free(error) }
            if let host { pairable_host_free(host) }
            if let serviceID { idevice_string_free(serviceID) }
            if let bytes { idevice_data_free(bytes, count) }
        }
        guard error == nil, host != nil, let serviceID, let bytes else { fatalError("Native host preparation failed") }
        let txt = try PropertyListSerialization.propertyList(from: Data(bytes: bytes, count: Int(count)), format: nil) as! [String: String]
        precondition(txt["identifier"] == String(cString: serviceID))
        precondition(txt["name"]?.hasPrefix("CarrierSelector-test-") == true)
        precondition(txt["model"] == "Mac17,7")
        precondition(txt["authTag"].flatMap { Data(base64Encoded: $0) }?.count == 6)
        precondition(irk != [UInt8](repeating: 0, count: 16))
        print("PASS: native idevice pairable_host_prepare ABI, Bonjour metadata, host identity and memory cleanup; no network pairing performed")
    }
}
