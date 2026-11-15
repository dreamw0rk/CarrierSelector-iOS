import Foundation

/// The opaque system token is bound to the exact pinned artifact, never reused for another catalog.
struct CatalogResumeStore {
    let file: URL
    private struct Record: Codable {
        let url: URL
        let digest: String
        let data: Data
    }
    func load(url: URL, digest: String) -> Data? {
        guard let bytes = try? Data(contentsOf: file),
              let record = try? PropertyListDecoder().decode(Record.self, from: bytes),
              record.url == url, record.digest == digest, !record.data.isEmpty else { return nil }
        return record.data
    }
    func save(_ data: Data?, url: URL, digest: String) {
        guard let data, !data.isEmpty else { clear(); return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(Record(url: url, digest: digest, data: data)).write(to: file, options: [.atomic, .completeFileProtection])
            var resource = file
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try resource.setResourceValues(values)
        } catch { clear() }
    }
    func clear() { try? FileManager.default.removeItem(at: file) }
}
