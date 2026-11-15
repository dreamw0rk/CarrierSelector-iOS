import Foundation
import CryptoKit

@main
struct TestRunner {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: \(name)") }
        count += 1
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: \(name) must reject") }
        catch { count += 1 }
    }
    @MainActor
    static func main() async throws {
        try workflowTests()
        try profileToolsTests()
        try await historyMigrationTests(modelURL: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("Library.momd"), storeURL: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(UUID().uuidString + ".sqlite"))
        await downloadTests(baseURL: URL(string: CommandLine.arguments[3])!)
        diagnosticsTests()
        try await directTelephonyModelTests()
        let imsi = "250011234567890", iccid = "8970101234567890123"
        check(try SIMIdentity.selector(imsi: imsi, iccid: iccid) == imsi + "_ID-" + iccid + "_ID-.bundle", "upstream selector grammar")
        check(SIMIdentity.normalizeICCID(iccid + "F") == iccid, "SIM padding nibble")
        rejects("non-ASCII digits") { _ = try SIMIdentity.selector(imsi: "٢٥٠٠١١٢٣٤٥٦٧٨٩٠", iccid: iccid) }
        rejects("selector path injection") { _ = try SIMIdentity.selector(imsi: "../../carrier", iccid: iccid) }
        rejects("short ICCID") { _ = try SIMIdentity.selector(imsi: imsi, iccid: "1234") }
        check(SIMIdentity.matches(imsi, mcc: "250", mnc: "1"), "MNC zero padding")
        check(!SIMIdentity.matches(imsi, mcc: "", mnc: "1"), "missing MCC")

        let row: [String: Any] = ["Slot": "kOne", "MCC": "250", "MNC": "01", "CFBundleIdentifier": "com.apple.MTS_ru", "CFBundleVersion": "73.0"]
        var values: [String: Any] = ["ProductType": "iPhone16,1", "HardwareModel": "D83AP", "UniqueDeviceID": "test-device",
                                   "ProductVersion": "27.2.1", "BuildVersion": "test", "CarrierBundleInfoArray": [row],
                                   "InternationalMobileSubscriberIdentity": imsi, "IntegratedCircuitCardIdentity": iccid]
        let device = try DeviceSnapshot.parse(values)
        check(device.lines.first?.selector != nil, "slot fallback resolves")
        check(device.lines.first?.maskedIdentity == "SIM •••• 0123", "SIM is masked")
        for version in ["26.0", "26.3", "26.4", "26.6.1", "27.0", "27.2.1"] {
            var versioned = values
            versioned["ProductVersion"] = version
            let parsed = try DeviceSnapshot.parse(versioned)
            check(parsed.version == version && parsed.lines.first?.selector != nil, "SIM parsing on iOS \(version)")
        }
        var second = row; second["Slot"] = "kTwo"
        values["CarrierBundleInfoArray"] = [second]
        values["InternationalMobileSubscriberIdentity2"] = "250019876543210"
        values["IntegratedCircuitCardIdentity2"] = "8970109876543210123"
        check(try DeviceSnapshot.parse(values).lines.first?.selector == nil, "ambiguous eSIM refuses guessing")
        values["InternationalMobileSubscriberIdentity2"] = imsi
        values["IntegratedCircuitCardIdentity2"] = iccid
        values["CarrierBundleInfoArray"] = [row, second]
        check(try DeviceSnapshot.parse(values).lines.allSatisfy { $0.selector == nil }, "duplicate selector disables both lines")
        values["CarrierBundleInfoArray"] = [row, row]
        rejects("duplicate slot IDs") { _ = try DeviceSnapshot.parse(values) }

        let profile = CarrierProfile(path: "test/MTS_ru.bundle", name: "MTS", identifier: "com.apple.MTS_ru", version: "73.0", supported: [], overrides: [["D83", "D84"]])
        check(profile.compatibility(hardware: "d83AP", product: "iPhone16,1") == 400, "case insensitive board matching")
        check(profile.compatibility(hardware: "D93AP", product: "iPhone17,1") == 50, "other board rejected")

        check(!PairingSupport.canCreate(onMajorVersion: 26), "on-device pairing unavailable on iOS 26")
        check(PairingSupport.canCreate(onMajorVersion: 27), "on-device pairing available on iOS 27")
        let key = Curve25519.Signing.PrivateKey()
        var record: [String: Any] = ["identifier": UUID().uuidString, "private_key": key.rawRepresentation,
                                     "public_key": key.publicKey.rawRepresentation, "alt_irk": Data(repeating: 1, count: 16)]
        func encodeRecord() throws -> Data { try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0) }
        try PairingRecord.validate(encodeRecord())
        count += 1
        record["public_key"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        rejects("mismatched pairing keys") { try PairingRecord.validate(encodeRecord()) }
        record["public_key"] = key.publicKey.rawRepresentation
        record["alt_irk"] = Data(repeating: 1, count: 15)
        rejects("truncated device identity key") { try PairingRecord.validate(encodeRecord()) }
        record["alt_irk"] = nil; record["identifier"] = " "
        rejects("empty pairing identifier") { try PairingRecord.validate(encodeRecord()) }
        rejects("legacy lockdown file") {
            try PairingRecord.validate(PropertyListSerialization.data(fromPropertyList: ["HostID": "legacy"], format: .xml, options: 0))
        }
        let cancelled = PairingSession()
        var interruptCount = 0
        let token = try cancelled.registerInterrupt { interruptCount += 1 }
        check(cancelled.cancel(), "first cancellation wins")
        check(!cancelled.cancel() && interruptCount == 1, "cancellation is idempotent")
        var saved = false
        rejects("cancelled pairing cannot replace keys") { try cancelled.commit { saved = true } }
        check(!saved, "old credentials untouched after cancellation")
        cancelled.unregisterInterrupt(token)
        rejects("no socket registered after cancellation") { _ = try cancelled.registerInterrupt {} }
        let committed = PairingSession()
        try committed.commit { saved = true }
        check(saved && !committed.cancel(), "late cancellation does not undo committed keys")
        rejects("keys saved once") { try committed.commit {} }
        let failedSave = PairingSession()
        rejects("storage error propagated") { try failedSave.commit { throw CarrierError.message("test failure") } }
        check(failedSave.cancel(), "failed save never marks the operation committed")

        let resourceRoot = URL(fileURLWithPath: CommandLine.arguments[1])
        let profiles = try JSONDecoder().decode([CarrierProfile].self, from: Data(contentsOf: resourceRoot.appendingPathComponent("profiles.json")))
        check(profiles.count > 1000, "catalog metadata populated")
        check(Set(profiles.map(\.id)).count == profiles.count, "unique package paths")
        let research = try ProfileResearch(directory: resourceRoot)
        check(research.capabilities.count == profiles.count && profiles.allSatisfy { research.capabilities[$0.path] != nil }, "every catalog variant has its own description")
        let telia68 = profiles.first { $0.identifier == "com.apple.Telia_dk" && $0.version == "68.0" }!
        let telia73 = profiles.first { $0.identifier == "com.apple.Telia_dk" && $0.version == "73.0" }!
        let vodafone = profiles.first { $0.identifier == "com.apple.Vodafone_ro" && $0.version == "73.0" }!
        let hungary = profiles.first { $0.identifier == "com.apple.Vodafone_hu" && $0.version == "73.0" }!
        let ukraine = profiles.first { $0.identifier == "com.apple.MTS_ua" && $0.version == "73.0" }!
        check(research.isCandidate(telia68, operator: .mts, hardware: nil), "Telia 68 candidate for MTS")
        check(!research.isCandidate(telia73, operator: .mts, hardware: nil), "Telia newer cipher mismatch excluded")
        check(!research.isCandidate(telia68, operator: .t2, hardware: nil), "no unsupported operator extrapolation")
        check(!research.isCandidate(telia68, operator: .mts, hardware: "NONEXISTENT"), "wrong board excluded")
        check(research.isCandidate(vodafone, operator: .mts, hardware: nil), "Vodafone Romania candidate for MTS")
        check(!research.isCandidate(hungary, operator: .mts, hardware: nil), "Hungary not recommended for MTS")
        check(research.isCandidate(hungary, operator: .beeline, hardware: nil), "Hungary candidate for Beeline")
        check(research.isCandidate(ukraine, operator: .t2, hardware: nil) && !research.isCandidate(ukraine, operator: .mts, hardware: nil), "MTS Ukraine is not inferred as MTS Russia")
        let future = CarrierProfile(path: vodafone.path, name: vodafone.name, identifier: vodafone.identifier, version: "99.0", supported: [], overrides: [])
        check(!research.isCandidate(future, operator: .mts, hardware: nil), "future versions need new evidence")
        let turkey = profiles.first { $0.identifier == "com.apple.Vodafone_tr" }!
        let nova = profiles.first { $0.identifier == "com.apple.Nova_is" }!
        check(!research.isCandidate(turkey, operator: .all, hardware: nil) && !research.blockers(for: turkey, hardware: nil).isEmpty, "local activation number is surfaced and excluded")
        check(!research.isCandidate(nova, operator: .t2, hardware: nil) && !research.blockers(for: nova, hardware: nil).isEmpty, "fixed ePDG excluded from ordinary trials")
        let unknown = profiles.first { $0.identifier == "com.apple.1and1_de" }!
        check(!research.isCandidate(unknown, operator: .all, hardware: nil), "no reports means no automatic recommendation")
        let missingSettings = ProfileResearch(document: research.document, capabilities: [:])
        check(!missingSettings.isCandidate(vodafone, operator: .mts, hardware: nil), "missing metadata fails closed")
        check(!research.rows(for: unknown, hardware: nil).isEmpty, "non-candidates still have package descriptions")
        let sourceIDs = Set(research.document.sources.map(\.id))
        check(research.document.rules.allSatisfy { Set($0.sourceIDs).isSubset(of: sourceIDs) && !$0.sourceIDs.isEmpty }, "all recommendations have cited sources")
        check(research.document.rules.allSatisfy { rule in rule.versions.allSatisfy { v in profiles.contains { $0.identifier == rule.identifier && $0.version == v } } }, "research refers to real catalog versions")
        check(ProfileSearch.matches(vodafone, query: "  МТС   73 ", research: research), "search Russian operator and version")
        check(ProfileSearch.matches(vodafone, query: "vodafone-ro", research: research), "search punctuation normalization")
        check(ProfileSearch.matches(vodafone, query: "Румыния", research: research), "search Russian country")
        check(ProfileSearch.matches(ukraine, query: "теле2", research: research), "search target operator alias")
        check(!ProfileSearch.matches(vodafone, query: "Vodafone 99", research: research), "search requires all words")
        check(ProfileSearch.matches(vodafone, query: "   ", research: research), "empty normalized query")

        let native = try JSONDecoder().decode(NativeCatalog.self, from: Data(contentsOf: resourceRoot.appendingPathComponent("native-profiles.json")))
        let mtsLine = device.lines[0]
        let stock = native.profile(for: mtsLine, device: device, profiles: profiles)
        check(stock?.identifier == "com.apple.MTS_ru", "stock resolved from SIM network, not installed donor")
        check(ProfileSearch.matches(stock!, query: "мтс", research: research), "Russian query finds native MTS package")
        var donorLine = SIMLine(id: mtsLine.id, name: mtsLine.name, imsi: mtsLine.imsi, iccid: mtsLine.iccid,
            bundleID: "com.apple.Vodafone_ro", version: "73.0", mcc: "250", mnc: "01")
        check(native.profile(for: donorLine, device: device, profiles: profiles)?.identifier == "com.apple.MTS_ru", "foreign active profile does not change stock identity")
        donorLine.mnc = "1"
        check(native.profile(for: donorLine, device: device, profiles: profiles)?.identifier == "com.apple.MTS_ru", "MNC leading zero normalized")
        donorLine.mcc = ""
        check(native.profile(for: donorLine, device: device, profiles: profiles) == nil, "missing network refuses stock guess")
        donorLine.mcc = "250"; donorLine.mnc = "02"
        check(native.profile(for: donorLine, device: device, profiles: profiles) == nil, "SIM identity must match claimed network")
        let ambiguous = NativeCatalog(families: native.families, supportedSIMs: Dictionary(uniqueKeysWithValues: profiles.map { ($0.path, ["25001"]) }))
        check(ambiguous.profile(for: mtsLine, device: device, profiles: profiles) == nil, "ambiguous stock mapping refuses reset")
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let carrierData = try PropertyListSerialization.data(fromPropertyList: ["SupportedSIMs": ["25001"], "Untouched": ["flag": true]], format: format, options: 0)
            let infoData = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.MTS_ru"], format: .binary, options: 0)
            let files: [(String, Data)] = [("Info.plist", infoData), ("carrier.plist", carrierData), ("signatures/common.plist", Data([1, 2, 3]))]
            let reset = try StockReset.files(from: files, expectedIdentifier: "com.apple.MTS_ru")
            let modified = try PropertyListSerialization.propertyList(from: reset[1].1, format: nil) as! [String: Any]
            check((modified["SupportedSIMs"] as? [String]) == [], "reset empties SupportedSIMs")
            check((modified["Untouched"] as? [String: Bool]) == ["flag": true] && reset[0].1 == infoData && reset[2].1 == files[2].1, "reset preserves other settings and bytes")
            rejects("wrong reset donor identity") { _ = try StockReset.files(from: files, expectedIdentifier: "com.apple.Vodafone_ro") }
        }
        let restore = InstallReceipt(deviceHash: InstallReceipt.hash(device.udid), selectorHash: InstallReceipt.hash(mtsLine.selector!), targetID: "com.apple.MTS_ru", targetVersion: "", previousID: "com.apple.Vodafone_ro", previousVersion: "73.0", date: Date(), operation: "restoreStock")
        check(!restore.verified(on: device, restartConfirmed: false), "restore cannot verify before explicit restart confirmation")
        check(restore.verified(on: device, restartConfirmed: true), "stock version chosen by OS, not donor version")
        let foreignDevice = DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: "other-device", lines: device.lines)
        check(!restore.verified(on: foreignDevice, restartConfirmed: true), "restore result bound to device")
        let changedSIM = SIMLine(id: mtsLine.id, name: mtsLine.name, imsi: "250019999999999", iccid: mtsLine.iccid, bundleID: mtsLine.bundleID, version: mtsLine.version)
        let changedSnapshot = DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: device.udid, lines: [changedSIM])
        check(!restore.verified(on: changedSnapshot, restartConfirmed: true), "restore result bound to exact SIM")
        let otherCarrier = SIMLine(id: mtsLine.id, name: mtsLine.name, imsi: mtsLine.imsi, iccid: mtsLine.iccid, bundleID: "com.apple.Vodafone_ro", version: "73.0")
        let stillForeign = DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: device.udid, lines: [otherCarrier])
        check(!restore.verified(on: stillForeign, restartConfirmed: true), "foreign profile after reboot keeps reset pending")
        let duplicated = DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: device.udid, lines: [mtsLine, mtsLine])
        check(!restore.verified(on: duplicated, restartConfirmed: true), "ambiguous receipt verification rejected")
        let oldReceipt = InstallReceipt(deviceHash: restore.deviceHash, selectorHash: restore.selectorHash, targetID: mtsLine.bundleID, targetVersion: mtsLine.version, previousID: "old", previousVersion: "1", date: Date())
        let decoded = try JSONDecoder().decode(InstallReceipt.self, from: JSONEncoder().encode(oldReceipt))
        check(!decoded.isRestore && decoded.verified(on: device, restartConfirmed: true), "old installation receipts remain readable")
        check(!decoded.verified(on: device, restartConfirmed: false), "refresh cannot silently finish installation before restart confirmation")
        check(!decoded.verified(on: foreignDevice, restartConfirmed: true), "installation confirmation belongs to exact device")
        check(!decoded.verified(on: changedSnapshot, restartConfirmed: true), "installation confirmation belongs to exact SIM")
        check(!decoded.verified(on: stillForeign, restartConfirmed: true), "wrong active profile keeps installation pending")

        let apn = try JSONDecoder().decode([APNEntry].self, from: Data(contentsOf: resourceRoot.appendingPathComponent("apn.json")))
        check(apn.count == 13 && apn.filter { $0.country == "Беларусь" }.count == 3, "upstream APN data")

        let testRoot = URL(fileURLWithPath: CommandLine.arguments[2])
        let storeURL = testRoot.appendingPathComponent(UUID().uuidString + ".sqlite")
        let modelURL = testRoot.appendingPathComponent("Library.momd")
        let library = LibraryStore(modelURL: modelURL, storeURL: storeURL)
        try await waitForStore(library)
        library.toggle(profile)
        check(library.favorites.contains(profile.identifier), "favorite saved")
        library.record(OperationEvent(title: "Test profile", detail: "Verified", date: Date()))
        check(library.history.count == 1, "operation saved")
        let reopened = LibraryStore(modelURL: modelURL, storeURL: storeURL)
        try await waitForStore(reopened)
        check(reopened.favorites.contains(profile.identifier), "favorite survives store reopen")
        check(reopened.history.first?.detail == "Verified", "history survives store reopen")
        reopened.toggle(profile)
        check(reopened.favorites.isEmpty, "favorite deletion persists")
        check(reopened.errorMessage == nil, "Core Data operations completed without error")
        print("PASS: \(count) checks (SIM identity, compatibility, pairing validation/cancellation, CommCenter diagnostics, profile research, catalog, Core Data persistence)")
    }
    @MainActor
    static func waitForStore(_ library: LibraryStore) async throws {
        for _ in 0..<100 {
            if library.ready { return }
            if let error = library.errorMessage { throw CarrierError.message(error) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CarrierError.message("Store loading timeout")
    }
}
