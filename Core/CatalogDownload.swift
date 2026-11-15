import Foundation

struct DownloadProgress: Equatable {
    enum Phase { case downloading, validating, cancelling }
    var received: Int64 = 0
    var expected: Int64? = nil
    var phase: Phase = .downloading
    var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}

/// One object per attempt. Delegate callbacks and file acceptance are serialized.
/// Cancellation wins before validation starts; once validation starts, the button is unavailable.
final class CatalogDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Accept = (URL) throws -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var validating = false
    private var finished = false
    private var completionReceived = false
    private var cancellationDataReceived = false
    private var cancellationData: Data?
    private var completionError: Error?
    private var resuming = false
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var acceptanceError: Error?
    private var accepted = false
    private let accept: Accept
    private let progress: (DownloadProgress) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private let configuration: URLSessionConfiguration
    private let resumeDataReceived: (Data?) -> Void

    init(configuration: URLSessionConfiguration = .ephemeral, accept: @escaping Accept,
         progress: @escaping (DownloadProgress) -> Void, resumeDataReceived: @escaping (Data?) -> Void = { _ in }, completion: @escaping (Result<Void, Error>) -> Void) {
        self.configuration = configuration; self.accept = accept
        self.progress = progress; self.completion = completion; self.resumeDataReceived = resumeDataReceived
    }
    func start(url: URL, resumeData: Data? = nil) {
        lock.lock()
        guard session == nil, !finished else { lock.unlock(); return }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        resuming = resumeData != nil
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        self.session = session; self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        task.resume()
        if shouldCancel { cancelTask(task) }
    }
    @discardableResult func cancel() -> Bool {
        lock.lock()
        guard !validating, !finished, !cancelled else { lock.unlock(); return false }
        cancelled = true
        let task = task
        lock.unlock()
        if let task { cancelTask(task) }
        return true
    }
    private func cancelTask(_ task: URLSessionDownloadTask) {
        task.cancel { data in
            self.lock.lock()
            self.cancellationData = data; self.cancellationDataReceived = true
            self.lock.unlock()
            self.finishIfReady()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        lock.lock(); let ignore = cancelled || finished; lock.unlock()
        if !ignore { progress(DownloadProgress(received: max(0, fileOffset), expected: expectedTotalBytes > 0 ? expectedTotalBytes : nil)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let ignore = cancelled || finished; lock.unlock()
        guard !ignore else { return }
        progress(DownloadProgress(received: max(0, totalBytesWritten), expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        guard !cancelled, !finished else { lock.unlock(); return }
        validating = true
        lock.unlock()
        guard let response = downloadTask.response as? HTTPURLResponse, (response.statusCode == 200 || (resuming && response.statusCode == 206)) else {
            acceptanceError = CarrierError.message("Сервер не предоставил пакеты. Повторите загрузку позже."); return
        }
        progress(DownloadProgress(received: max(0, downloadTask.countOfBytesReceived), phase: .validating))
        do { try accept(location); accepted = true } catch { acceptanceError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        completionReceived = true; completionError = error
        lock.unlock()
        finishIfReady()
    }
    private func finishIfReady() {
        lock.lock()
        guard !finished, completionReceived, !cancelled || cancellationDataReceived else { lock.unlock(); return }
        finished = true
        let wasCancelled = cancelled
        let failure = acceptanceError ?? completionError
        let resume = wasCancelled ? cancellationData : (completionError as NSError?)?.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
        let session = self.session
        self.task = nil; self.session = nil
        lock.unlock()
        // Persist before notifying the UI, even when cancellation callbacks arrive out of order.
        resumeDataReceived(accepted ? nil : resume)
        session?.finishTasksAndInvalidate()
        if wasCancelled { completion(.failure(CancellationError())) }
        else if let failure { completion(.failure(failure)) }
        else if accepted { completion(.success(())) }
        else { completion(.failure(CarrierError.message("Загрузка не завершена. Повторите попытку."))) }
    }
}
