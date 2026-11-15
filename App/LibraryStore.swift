import Foundation
import CoreData
import Combine

struct OperationEvent: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let date: Date
    let context: OperationContext?
    init(id: UUID = UUID(), title: String, detail: String, date: Date, context: OperationContext? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.date = date; self.context = context
    }
}

/// UI-sized writes and fetches use the main-queue view context. No managed objects leave it.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var favorites = Set<String>()
    @Published private(set) var history: [OperationEvent] = []
    @Published private(set) var historySIMs: [HistorySIM] = []
    @Published private(set) var historyFilter: String?
    @Published private(set) var ready = false
    @Published private(set) var errorMessage: String?
    private let container: NSPersistentContainer
    private var queuedEvents: [OperationEvent] = []

    init(inMemory: Bool = false, modelURL: URL? = nil, storeURL: URL? = nil) {
        if let modelURL, let model = NSManagedObjectModel(contentsOf: modelURL) {
            container = NSPersistentContainer(name: "Library", managedObjectModel: model)
        } else { container = NSPersistentContainer(name: "Library") }
        let destination = storeURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Library.sqlite")
        let description = NSPersistentStoreDescription(url: destination)
        if inMemory { description.type = NSInMemoryStoreType }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        if !inMemory {
            do { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
            catch { errorMessage = "Хранилище недоступно: \(error.localizedDescription)"; return }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.name = "LibraryUI"
        container.loadPersistentStores { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.errorMessage = "История и избранное недоступны: \(error.localizedDescription)"; return }
                self.ready = true
                self.reload()
                let events = self.queuedEvents
                self.queuedEvents.removeAll()
                events.forEach(self.record)
            }
        }
    }
    func toggle(_ profile: CarrierProfile) {
        guard ready else { return }
        let context = container.viewContext
        do {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Favorite")
            request.predicate = NSPredicate(format: "profileID == %@", profile.identifier)
            let existing = try context.fetch(request)
            if existing.isEmpty {
                let object = NSEntityDescription.insertNewObject(forEntityName: "Favorite", into: context)
                object.setValue(profile.identifier, forKey: "profileID")
            } else { existing.forEach(context.delete) }
            try context.save()
            errorMessage = nil
            reload()
        } catch { context.rollback(); errorMessage = "Не удалось сохранить избранное: \(error.localizedDescription)" }
    }
    func record(_ event: OperationEvent) {
        guard ready else { queuedEvents.append(event); return }
        let context = container.viewContext
        let object = NSEntityDescription.insertNewObject(forEntityName: "Operation", into: context)
        object.setValue(event.id, forKey: "id")
        object.setValue(event.title, forKey: "title")
        object.setValue(event.detail, forKey: "detail")
        object.setValue(event.date, forKey: "date")
        object.setValue(event.context?.simKey, forKey: "simKey")
        object.setValue(event.context?.simLabel, forKey: "simLabel")
        object.setValue(event.context.flatMap { try? JSONEncoder().encode($0) }, forKey: "contextData")
        do { try context.save(); reload() }
        catch { context.rollback(); errorMessage = "Не удалось сохранить историю: \(error.localizedDescription)" }
    }
    func filterHistory(_ key: String?) {
        historyFilter = key
        if ready { reload() }
    }
    private func reload() {
        do {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Favorite")
            favorites = Set(try container.viewContext.fetch(request).compactMap { $0.value(forKey: "profileID") as? String })
            let groups = NSFetchRequest<NSDictionary>(entityName: "Operation")
            groups.resultType = .dictionaryResultType
            groups.propertiesToFetch = ["simKey", "simLabel"]
            groups.returnsDistinctResults = true
            let grouped = try container.viewContext.fetch(groups)
            var labels: [String: String] = [:]
            for row in grouped {
                if let key = row["simKey"] as? String, let label = row["simLabel"] as? String {
                    if labels[key] == nil || labels[key] == "SIM предыдущей операции" { labels[key] = label }
                }
            }
            historySIMs = labels.map { HistorySIM(id: $0.key, label: $0.value) }.sorted { $0.id < $1.id }
            let operations = NSFetchRequest<NSManagedObject>(entityName: "Operation")
            if let historyFilter {
                operations.predicate = historyFilter == "legacy" ? NSPredicate(format: "simKey == nil") : NSPredicate(format: "simKey == %@", historyFilter)
            }
            operations.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            operations.fetchLimit = 100
            history = try container.viewContext.fetch(operations).compactMap {
                guard let id = $0.value(forKey: "id") as? UUID, let title = $0.value(forKey: "title") as? String,
                      let detail = $0.value(forKey: "detail") as? String, let date = $0.value(forKey: "date") as? Date else { return nil }
                let context = ($0.value(forKey: "contextData") as? Data).flatMap { try? JSONDecoder().decode(OperationContext.self, from: $0) }
                return OperationEvent(id: id, title: title, detail: detail, date: date, context: context)
            }
        } catch { errorMessage = "Не удалось прочитать историю: \(error.localizedDescription)" }
    }
}
