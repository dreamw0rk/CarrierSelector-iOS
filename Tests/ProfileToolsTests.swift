import Foundation
import CoreData

extension TestRunner {
    static func profileToolsTests() throws {
        let a = CarrierProfile(path: "a", name: "A", identifier: "com.apple.A", version: "9.0", supported: [], overrides: [])
        let b = CarrierProfile(path: "b", name: "A", identifier: "com.apple.A", version: "10.0", supported: [], overrides: [])
        let c = CarrierProfile(path: "c", name: "B", identifier: "com.apple.B", version: "1.0", supported: [], overrides: [])
        check(ProfileCatalogLookup.versions(identifier: a.identifier, device: nil, profiles: [a,b,c]).map(\.version) == ["10.0", "9.0"], "catalog versions sorted numerically and scoped to package")
        check(ProfileCatalogLookup.exact(identifier: a.identifier, version: "8.0", device: nil, profiles: [a,b]).isEmpty, "current profile lookup never substitutes a newer version")
        let cap = try JSONDecoder().decode(ProfileCapabilities.self, from: Data("{\"boards\":[],\"apn\":[],\"registration\":[],\"volte\":true}".utf8))
        let other = try JSONDecoder().decode(ProfileCapabilities.self, from: Data("{\"boards\":[],\"apn\":[],\"registration\":[],\"volte\":false}".utf8))
        let research = ProfileResearch(document: ResearchDocument(sources: [], rules: []), capabilities: [a.path:[cap], c.path:[other]])
        let compare = ProfileComparison(first: a, second: c, device: nil, profiles: [a,c], research: research)
        check(compare.changed.map(\.id) == ["volte"], "arbitrary packages compare offline without SIM")
        let reversed = ProfileComparison(first: c, second: a, device: nil, profiles: [a,c], research: research)
        check(compare.rows[0].current == reversed.rows[0].selected, "swapping comparison swaps values")
        check(RussianOperator.inferred(nativeIdentifier: "com.apple.MTS_ru") == .mts, "native MTS maps to operator filter")
        check(RussianOperator.inferred(nativeIdentifier: "com.apple.MegaFon_Yota_ru") == .yota, "native Yota stays separate from MegaFon")
        check(RussianOperator.inferred(nativeIdentifier: "com.apple.Vodafone_ro") == nil, "foreign donor cannot infer Russian operator")
        check(RussianOperator.inferred(nativeIdentifier: "com.apple.Tele2_Sberbank_ru") == nil, "unmapped virtual operator is not guessed as host network")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CatalogResumeStore(file: file)
        defer { store.clear() }
        let url = URL(string: "https://example.invalid/catalog")!
        store.save(Data([1,2,3]), url: url, digest: "v1")
        check(CatalogResumeStore(file: file).load(url: url, digest: "v1") == Data([1,2,3]), "resume token persists across store instances")
        check(store.load(url: url, digest: "v2") == nil, "resume token bound to catalog hash")
        check(store.load(url: URL(string: "https://example.invalid/other")!, digest: "v1") == nil, "resume token bound to original URL")
        store.save(nil, url: url, digest: "v1")
        check(store.load(url: url, digest: "v1") == nil, "success clears resume token")
    }

    @MainActor static func historyMigrationTests(modelURL: URL, storeURL: URL) async throws {
        let old = NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent("Library.mom"))!
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let legacy = NSEntityDescription.insertNewObject(forEntityName: "Operation", into: context)
        legacy.setValue(UUID(), forKey: "id"); legacy.setValue("Legacy", forKey: "title")
        legacy.setValue("Old operation", forKey: "detail"); legacy.setValue(Date.distantPast, forKey: "date")
        let favorite = NSEntityDescription.insertNewObject(forEntityName: "Favorite", into: context)
        favorite.setValue("com.apple.Example", forKey: "profileID")
        try context.save(); context.reset(); try coordinator.remove(store)
        let library = LibraryStore(modelURL: modelURL, storeURL: storeURL)
        try await waitForStore(library)
        check(library.history.first?.title == "Legacy" && library.history.first?.context == nil, "v1 SQLite history migrated without invented SIM")
        check(library.favorites.contains("com.apple.Example"), "migration preserves favorites")
        let line = SIMLine(id: "kOne", name: "Example", imsi: "250011234567890", iccid: "8970101234567890123", bundleID: "com.apple.Before", version: "1.0")
        let device = DeviceSnapshot(product: "iPhone16,1", hardware: "D83AP", version: "27.0", build: "test", udid: "device", lines: [line])
        let target = CarrierProfile(path: "target", name: "After", identifier: "com.apple.After", version: "2.0", supported: [], overrides: [])
        let details = OperationContext(device: device, line: line, target: target)!
        library.record(OperationEvent(title: "Sent", detail: "Pending", date: Date(), context: details))
        library.filterHistory(details.simKey)
        check(library.history.count == 1 && library.history.first?.context == details, "per-SIM fetch retains before and target versions")
        library.filterHistory("legacy")
        check(library.history.count == 1 && library.history.first?.title == "Legacy", "legacy history remains separately accessible")
        let receipt = InstallReceipt(deviceHash: InstallReceipt.hash(device.udid), selectorHash: InstallReceipt.hash(line.selector!), targetID: target.identifier, targetVersion: target.version, previousID: line.bundleID, previousVersion: line.version, date: Date())
        let confirmed = OperationContext(receipt: receipt, line: line, active: line)
        check(confirmed.simKey == details.simKey, "send and verification share SIM history key")
        library.record(OperationEvent(title: "Checked", detail: "Different", date: Date(), context: confirmed))
        library.filterHistory(details.simKey)
        check(library.history.count == 2 && library.history.first?.context?.activeVersion == "1.0", "verification records actual profile version")
        let sameSIMOtherDevice = OperationContext.key(deviceHash: InstallReceipt.hash("other"), selectorHash: receipt.selectorHash)
        check(sameSIMOtherDevice != details.simKey, "history separates same SIM across devices")
        let encoded = String(data: try JSONEncoder().encode(details), encoding: .utf8)!
        check(!encoded.contains(line.imsi) && !encoded.contains(line.iccid) && !encoded.contains(device.udid + "\""), "history has no full SIM or device identifiers")
        let reopened = LibraryStore(modelURL: modelURL, storeURL: storeURL)
        try await waitForStore(reopened)
        reopened.filterHistory(details.simKey)
        check(reopened.history.count == 2 && reopened.historySIMs.count == 1, "SIM groups survive database reopen")
    }
}
