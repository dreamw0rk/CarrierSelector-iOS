import Foundation

extension TestRunner {
    static func workflowTests() throws {
        let line = SIMLine(id: "kOne", name: "Test", imsi: "250011234567890", iccid: "8970101234567890123", bundleID: "com.apple.Current", version: "1.0")
        let device = DeviceSnapshot(product: "iPhone16,1", hardware: "D83AP", version: "26.0", build: "test", udid: "test-phone", lines: [line])
        let current = CarrierProfile(path: "current", name: "Current", identifier: line.bundleID, version: line.version, supported: [], overrides: [["D83"]])
        let target = CarrierProfile(path: "target", name: "Target", identifier: "com.apple.Target", version: "2.0", supported: [], overrides: [["D83"]])
        func capabilities(_ fields: [String: Any]) throws -> ProfileCapabilities {
            let base: [String: Any] = ["boards": ["D83"], "apn": ["b", "a"], "registration": []]
            return try JSONDecoder().decode(ProfileCapabilities.self, from: JSONSerialization.data(withJSONObject: base.merging(fields, uniquingKeysWith: { _, value in value })))
        }
        let old = try capabilities(["volte": false, "wifiWithoutEntitlement": false, "fiveGSwitch": true])
        let new = try capabilities(["volte": true, "wifiWithoutEntitlement": true, "fiveGSwitch": true, "apn": ["a", "b", "a"]])
        func compare(_ profiles: [CarrierProfile], _ values: [String: [ProfileCapabilities]]) -> ProfileComparison {
            ProfileComparison(current: line, selected: target, device: device, profiles: profiles,
                research: ProfileResearch(document: ResearchDocument(sources: [], rules: []), capabilities: values))
        }
        let comparison = compare([current, target], ["current": [old], "target": [new]])
        check(comparison.changed.map(\.id) == ["volte", "wifi"], "compare explicit true/false changes")
        check(comparison.unchanged.map(\.id) == ["5g", "apn"], "APN order and duplicates do not create differences")
        check(comparison.unknown.map(\.id) == ["evs", "apnEdit"], "missing on both sides remains unknown, not unchanged")
        let missingVersion = CarrierProfile(path: "wrong-version", name: "Current", identifier: line.bundleID, version: "9.0", supported: [], overrides: [])
        let absent = compare([missingVersion, target], [missingVersion.path: [old], target.path: [new]])
        check(!absent.currentFound && absent.changed.isEmpty && absent.unknown.count == 6, "never substitute another installed version")
        let wrongBoard = CarrierProfile(path: "wrong-board", name: "Current", identifier: line.bundleID, version: line.version, supported: [], overrides: [["D99"]])
        check(!compare([wrongBoard], [wrongBoard.path: [old]]).currentFound, "exclude incompatible current board")
        let generic = CarrierProfile(path: "generic", name: "Current", identifier: line.bundleID, version: line.version, supported: [], overrides: [])
        let preferred = compare([generic, current], [generic.path: [new], current.path: [old], target.path: [new]])
        check(preferred.changed.contains { $0.id == "volte" }, "prefer board-specific metadata to generic package")
        let ambiguous = compare([current], [current.path: [old, new], target.path: [new]])
        check(ambiguous.rows.first?.current == .ambiguous && !ambiguous.rows[0].changed, "conflicting variants cannot claim a change")
        let peer = CarrierProfile(path: "peer", name: "Current", identifier: line.bundleID, version: line.version, supported: [], overrides: [["D83"]])
        check(compare([current, peer], [current.path: [old], target.path: [new]]).rows[0].current == .unknown, "missing equally ranked package must not be dropped")
        check(ComparedValue.consensus([nil, "Да"]) == .unknown, "partial variant data stays unknown")
        check(ComparedValue.consensus([]) == .unknown, "no variants stays unknown")

        var draft = InstallationDraft(profilePath: target.path, profileIdentifier: target.identifier, profileVersion: target.version)
        draft.select(line: line, device: device)
        let suite = "CarrierSelector.WorkflowTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        InstallationDraftStore(defaults: defaults).save(draft)
        let restored = InstallationDraftStore(defaults: UserDefaults(suiteName: suite)!).load()
        check(restored == draft && restored.profile(in: [current, target])?.path == target.path, "restore exact profile and selected SIM from persisted draft")
        check(restored.profile(in: [current]) == nil, "removed profile never silently changes to another")
        let revised = CarrierProfile(path: target.path, name: target.name, identifier: target.identifier, version: "3.0", supported: [], overrides: [])
        check(restored.profile(in: [revised]) == nil, "saved choice cannot silently upgrade a package at the same path")
        let moved = SIMLine(id: "kTwo", name: line.name, imsi: line.imsi, iccid: line.iccid, bundleID: line.bundleID, version: line.version)
        let movedDevice = DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: device.udid, lines: [moved])
        check(restored.lineID(on: movedDevice) == "kTwo", "SIM selection follows identity after slot move")
        let replaced = SIMLine(id: line.id, name: line.name, imsi: "250019999999999", iccid: line.iccid, bundleID: line.bundleID, version: line.version)
        let replacedDevice = DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: device.udid, lines: [replaced])
        check(restored.lineID(on: replacedDevice) == nil, "new SIM in old slot is not auto-selected")
        let other = DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: "other", lines: [line])
        check(restored.lineID(on: other) == nil, "draft cannot select SIM on another device")
        let duplicate = DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: device.udid, lines: [line, moved])
        check(restored.lineID(on: duplicate) == nil, "ambiguous SIM draft requires manual choice")
        let encoded = String(data: try JSONEncoder().encode(draft), encoding: .utf8)!
        check(!encoded.contains(line.imsi) && !encoded.contains(line.iccid) && !encoded.contains(device.udid), "draft contains no raw phone or SIM identities")

        let receipt = InstallReceipt(deviceHash: InstallReceipt.hash(device.udid), selectorHash: InstallReceipt.hash(line.selector!), targetID: line.bundleID, targetVersion: line.version, previousID: "old", previousVersion: "1", date: Date())
        func result(_ snapshot: DeviceSnapshot, _ confirmed: Bool = true, _ record: InstallReceipt? = nil) -> ProfileVerification.Outcome {
            ProfileVerification(receipt: record ?? receipt, device: snapshot, restartConfirmed: confirmed).outcome
        }
        check(result(device) == .verified, "exact verification success")
        check(result(device, false) == .restartRequired, "read-only refresh is not post-restart verification")
        check(result(other) == .wrongDevice, "verification identifies wrong phone")
        check(result(replacedDevice) == .simMissing, "verification identifies missing SIM")
        check(result(duplicate) == .ambiguousSIM, "verification identifies ambiguous SIM")
        func withProfile(_ id: String, _ version: String) -> DeviceSnapshot {
            let active = SIMLine(id: line.id, name: line.name, imsi: line.imsi, iccid: line.iccid, bundleID: id, version: version)
            return DeviceSnapshot(product: device.product, hardware: device.hardware, version: device.version, build: device.build, udid: device.udid, lines: [active])
        }
        check(result(withProfile("com.apple.Other", "1.0")) == .differentProfile, "verification distinguishes wrong package")
        check(result(withProfile(line.bundleID, "2.0")) == .differentVersion, "verification distinguishes wrong version")
        check(result(withProfile(line.bundleID, "")) == .unreadableProfile, "verification handles missing version")
        check(result(withProfile(line.bundleID, "0")) == .unreadableProfile, "verification rejects reset sentinel")
        var reset = receipt; reset.operation = "restoreStock"
        check(result(withProfile(line.bundleID, "2.0"), true, reset) == .verified, "stock reset permits system-chosen version")
        check(result(device, false, reset) == .restartRequired, "stock reset requires explicit reboot confirmation")
        let failure = ProfileVerification(receipt: receipt, device: other, restartConfirmed: true)
        check(failure.active == nil, "wrong device exposes no comparison with unrelated SIM")

        check(ConnectionFailure.ffi(operation: "test", code: 23, subcode: 0).reason == .locked, "known device-locked error has unlock recovery")
        check(ConnectionFailure.ffi(operation: "test", code: 103, subcode: 5).needsPairing, "pair verify failure suggests pairing recovery")
        check(!ConnectionFailure.ffi(operation: "test", code: 103, subcode: 1).needsPairing, "unknown TLV does not prove invalid pairing")
        check(ConnectionFailure.ffi(operation: "test", code: 1, subcode: 0).reason == .transport, "socket error is transport failure, not VPN-off assertion")
        check(ConnectionFailure.ffi(operation: "test", code: 109, subcode: 0).reason == .timeout, "timeout has distinct recovery")
        check(ConnectionFailure.ffi(operation: "test", code: 999, subcode: 42).technical == "test · 999/42", "unknown errors preserve numeric code only")
        check(DownloadProgress(received: 50, expected: 100).fraction == 0.5, "download percentage uses real bytes")
        check(DownloadProgress(received: 10).fraction == nil, "unknown length has no guessed percentage")
        check(DownloadProgress(received: 200, expected: 100).fraction == 1, "percentage stays bounded")
    }

    @MainActor static func downloadTests(baseURL: URL) async {
        let success = await exerciseDownload(baseURL.appendingPathComponent("ok"))
        check(success.0 && success.1.acceptedBytes == 262144, "HTTP download delivered complete file for validation")
        check(success.1.progress.contains { $0.expected == 262144 && $0.received > 0 }, "URLSession delegate reports byte progress")
        check(success.1.progress.contains { $0.phase == .validating }, "download enters validation before success")
        let unknown = await exerciseDownload(baseURL.appendingPathComponent("unknown"))
        check(unknown.0 && unknown.1.progress.contains { $0.expected == nil && $0.phase == .downloading }, "unknown response size remains indeterminate")
        let notFound = await exerciseDownload(baseURL.appendingPathComponent("missing"))
        check(!notFound.0 && notFound.1.acceptedBytes == 0, "non-200 response never becomes a catalog")
        let rejected = await exerciseDownload(baseURL.appendingPathComponent("ok"), reject: true)
        check(!rejected.0, "validation failure does not report download success")
        let cancelled = await exerciseDownload(baseURL.appendingPathComponent("slow"), cancel: true)
        check(!cancelled.0 && cancelled.1.cancelled && cancelled.1.acceptedBytes == 0, "cancelled download cannot publish a catalog")
        let retry = await exerciseDownload(baseURL.appendingPathComponent("ok"))
        check(retry.0, "new attempt succeeds after cancellation")
        let paused = await exerciseDownload(baseURL.appendingPathComponent("resumable"), cancel: true, cancelAfter: 65536)
        check(!paused.0 && paused.1.resumeData != nil, "pause produces system resume data before completion")
        let resumed = await exerciseDownload(baseURL.appendingPathComponent("resumable"), resumeData: paused.1.resumeData)
        check(resumed.0 && resumed.1.acceptedBytes == 262144, "HTTP range resume delivers complete assembled file")
        check((resumed.1.progress.first?.received ?? 0) >= 65536, "resume starts from saved offset")
        check(resumed.1.resumeData == nil, "successful resumed download clears resume data")
        let interrupted = await exerciseDownload(baseURL.appendingPathComponent("interrupted"))
        check(!interrupted.0 && interrupted.1.resumeData != nil, "network interruption preserves system resume data")
        let recovered = await exerciseDownload(baseURL.appendingPathComponent("interrupted"), resumeData: interrupted.1.resumeData)
        check(recovered.0 && recovered.1.acceptedBytes == 262144, "network interruption resumes remaining bytes")
        let expired = await exerciseDownload(baseURL.appendingPathComponent("expired"), cancel: true, cancelAfter: 65536)
        check(expired.1.resumeData != nil, "fallback fixture creates resume token")
        let restarted = await exerciseDownload(baseURL.appendingPathComponent("expired"), resumeData: expired.1.resumeData)
        check(restarted.0 && restarted.1.acceptedBytes == 262144, "server rejecting range can restart whole download safely")
        let validation = await exerciseDownload(baseURL.appendingPathComponent("ok"), cancelDuringValidation: true)
        check(validation.0 && validation.1.cancelRejected, "late cancellation cannot contradict accepted catalog")
    }

    private static func exerciseDownload(_ url: URL, reject: Bool = false, cancel: Bool = false,
                                         cancelDuringValidation: Bool = false, cancelAfter: Int64 = 0, resumeData: Data? = nil) async -> (Bool, DownloadProbe) {
        let probe = DownloadProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let success: Bool = await withCheckedContinuation { continuation in
            let download = CatalogDownload(configuration: configuration, accept: { file in
                if cancelDuringValidation { probe.cancelDuringValidation() }
                if reject { throw CarrierError.message("Invalid fixture hash") }
                let data = try Data(contentsOf: file)
                probe.recordBytes(data.count)
            }, progress: { progress in
                probe.record(progress)
                if cancel && progress.phase == .downloading && progress.received > 0 && progress.received >= cancelAfter { probe.cancel() }
            }, resumeDataReceived: { probe.recordResumeData($0) }, completion: { result in
                switch result {
                case .success: continuation.resume(returning: true)
                case .failure(let error): probe.recordCancelled(error is CancellationError); continuation.resume(returning: false)
                }
            })
            probe.set(download)
            download.start(url: url, resumeData: resumeData)
        }
        return (success, probe)
    }
}

private final class DownloadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DownloadProgress] = []
    private var bytes = 0
    private var wasCancelled = false
    private var lateCancelRejected = false
    private var resume: Data?
    var resumeData: Data? { lock.lock(); defer { lock.unlock() }; return resume }
    func recordResumeData(_ value: Data?) { lock.lock(); resume = value; lock.unlock() }
    private weak var download: CatalogDownload?
    var progress: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return values }
    var acceptedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return wasCancelled }
    var cancelRejected: Bool { lock.lock(); defer { lock.unlock() }; return lateCancelRejected }
    func set(_ value: CatalogDownload) { lock.lock(); download = value; lock.unlock() }
    func record(_ value: DownloadProgress) { lock.lock(); values.append(value); lock.unlock() }
    func recordBytes(_ value: Int) { lock.lock(); bytes = value; lock.unlock() }
    func recordCancelled(_ value: Bool) { lock.lock(); wasCancelled = value; lock.unlock() }
    func cancel() { lock.lock(); let download = download; lock.unlock(); download?.cancel() }
    func cancelDuringValidation() {
        lock.lock(); let download = download; lock.unlock()
        let rejected = download?.cancel() == false
        lock.lock(); lateCancelRejected = rejected; lock.unlock()
    }
}
