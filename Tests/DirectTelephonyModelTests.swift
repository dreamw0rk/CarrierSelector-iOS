import Foundation

extension TestRunner {
    @MainActor
    static func directTelephonyModelTests() async throws {
        func pause() async throws { try await Task.sleep(nanoseconds: 150_000_000) }
        let released = DispatchSemaphore(value: 0)
        let model = DirectTelephonyModel(timeout: 0.1) { continuing, deliver in
            deliver([["slot": 1, "metric": "imsConnection", "status": "value", "value": true, "date": Date()]])
            _ = released.wait(timeout: .now() + 3)
            // Simulate an OS method returning after the UI timeout.
            deliver([["slot": 2, "metric": "imsVoice", "status": "value", "value": false, "date": Date()]])
        }
        model.start()
        try await pause()
        check(!model.running && model.waitingForCall, "timeout releases UI but keeps in-flight native call guarded")
        check(model.readings.first?.metric == .imsConnection, "timeout preserves already delivered direct fields")
        model.refresh()
        check(model.readings.first?.metric == .imsConnection && !model.running, "timeout cannot enqueue another call on blocked worker")
        released.signal()
        try await pause()
        check(!model.waitingForCall, "native completion releases the in-flight guard")
        check(model.readings.first?.metric == .imsConnection && model.readings.count == 1, "late private response cannot overwrite timeout result")
        model.stop()

        let held = DispatchSemaphore(value: 0)
        let stopped = DirectTelephonyModel(timeout: 1) { _, deliver in
            _ = held.wait(timeout: .now() + 3)
            deliver([["slot": 1, "metric": "imsVoice", "status": "value", "value": true, "date": Date()]])
        }
        stopped.start(); stopped.stop(); held.signal()
        try await pause()
        check(stopped.readings.isEmpty && !stopped.running && !stopped.waitingForCall, "leaving screen prevents stale result delivery")
        stopped.start()
        held.signal()
        try await pause()
        check(stopped.readings.first?.value == true && !stopped.running, "returning to screen starts a new direct request")
        stopped.stop()
    }
}
