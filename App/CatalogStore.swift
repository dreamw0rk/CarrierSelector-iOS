import Foundation
import CryptoKit
import ZIPFoundation

final class CatalogStore {
    static let archiveURL = URL(string: "https://github.com/carrierselector/CarrierSelector/releases/download/catalog-ios27.2.1/embedded_catalog-ios27.2.1.zip")!
    static let digest = "f6dbfd8bb075f210ee25b9c38b46cb1f57ea4f5c3cb46f99a796054c7f4e4fad"
    let profiles: [CarrierProfile]
    let models: [String: [String]]
    let research: ProfileResearch
    let researchError: String?
    let nativeCatalog: NativeCatalog?
    let archivePath: URL
    init() {
        nativeCatalog = Bundle.main.url(forResource: "native-profiles", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(NativeCatalog.self, from: $0) }
        do {
            guard let directory = Bundle.main.resourceURL else { throw CarrierError.message("Нет ресурсов приложения") }
            research = try ProfileResearch(directory: directory)
            researchError = nil
        } catch {
            research = .empty
            researchError = "Не удалось прочитать описания профилей. Отбор для РФ недоступен."
        }
        archivePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("carrier-catalog.zip")
        profiles = Bundle.main.url(forResource: "profiles", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([CarrierProfile].self, from: $0) } ?? []
        models = Bundle.main.url(forResource: "models", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }
    func supports(_ device: DeviceSnapshot) -> Bool {
        models[device.product]?.contains(where: { $0.lowercased() == device.hardware.lowercased() }) == true
    }
    func stockProfile(for line: SIMLine, device: DeviceSnapshot) -> CarrierProfile? {
        nativeCatalog?.profile(for: line, device: device, profiles: profiles)
    }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: archivePath.path) }
    func validate(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == Self.digest else {
            throw CarrierError.message("Загруженный каталог повреждён или не соответствует версии приложения. Попробуйте загрузить его заново.")
        }
    }
    func acceptDownload(_ temporary: URL) throws {
        try validate(temporary)
        let staged = archivePath.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: temporary, to: staged)
        if isDownloaded { _ = try FileManager.default.replaceItemAt(archivePath, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: archivePath) }
    }
    func available(for device: DeviceSnapshot?) -> [CarrierProfile] {
        var best: [String: CarrierProfile] = [:]
        for profile in profiles {
            let score = device.map { profile.compatibility(hardware: $0.hardware, product: $0.product) } ?? 100
            guard score != 50 else { continue }
            let key = profile.identifier + "@" + profile.version
            if let current = best[key], let device,
               current.compatibility(hardware: device.hardware, product: device.product) >= score { continue }
            if best[key] == nil || device != nil { best[key] = profile }
        }
        return best.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func files(for profile: CarrierProfile) throws -> [(String, Data)] {
        try validate(archivePath)
        let archive = try Archive(url: archivePath, accessMode: .read)
        let prefix = "embedded_catalog/" + profile.path + "/"
        var files: [(String, Data)] = []
        var total: UInt64 = 0
        for entry in archive where entry.path.hasPrefix(prefix) {
            guard entry.type != .directory else { continue }
            let relative = String(entry.path.dropFirst(prefix.count))
            guard entry.type == .file, !relative.hasPrefix("/"), !relative.contains("\\"),
                  !relative.split(separator: "/").contains("..") else { throw CarrierError.message("Некорректный путь в пакете.") }
            total += entry.uncompressedSize
            guard total < 64_000_000 else { throw CarrierError.message("Слишком большой профиль.") }
            var data = Data()
            _ = try archive.extract(entry, consumer: { data.append($0) })
            files.append((relative, data))
        }
        let dictionary = Dictionary(uniqueKeysWithValues: files)
        guard let infoData = dictionary["Info.plist"], dictionary["carrier.plist"] != nil,
              dictionary["signatures/common.plist"] != nil,
              let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == profile.identifier,
              info["CFBundleVersion"] as? String == profile.version else { throw CarrierError.message("Пакет не соответствует каталогу.") }
        return files
    }
}
