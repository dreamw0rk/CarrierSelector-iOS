import Foundation

enum PairingSupport {
    static func canCreate(onMajorVersion version: Int) -> Bool { version >= 27 }
}

/// Cancellation and saving have a single ordering: cancellation wins before commit,
/// or commit wins and a late cancellation cannot report that saved keys were discarded.
final class PairingSession {
    private let lock = NSLock()
    private var cancelled = false
    private var committed = false
    private var interrupts: [UUID: () -> Void] = [:]

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    @discardableResult
    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !committed, !cancelled else { return false }
        cancelled = true
        // Interrupts must be nonblocking and must not call back into this session.
        interrupts.values.forEach { $0() }
        return true
    }
    func registerInterrupt(_ interrupt: @escaping () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        let id = UUID()
        interrupts[id] = interrupt
        return id
    }
    func unregisterInterrupt(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        interrupts.removeValue(forKey: id)
    }
    func commit(_ save: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        guard !committed else { throw CarrierError.message("Pairing уже сохранён.") }
        try save()
        committed = true
    }
}
