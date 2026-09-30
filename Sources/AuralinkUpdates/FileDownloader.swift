import Foundation

// Adapted from MiSTer FTP (MIT); see third_party/licenses/MiSTer-FTP-LICENSE.

/// Downloads one file to `destination` and reports progress. `file://` URLs work too.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let maximumSize: Int64
    private let allowingLocalFiles: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    init(destination: URL, maximumSize: Int64, allowingLocalFiles: Bool = false, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.maximumSize = maximumSize
        self.allowingLocalFiles = allowingLocalFiles
        self.progress = progress
    }

    func run(_ url: URL) async throws {
        guard ReleaseFeed.isAllowed(url, allowingLocalFiles: allowingLocalFiles) else { throw UpdateError.insecureURL }
        try Task.checkCancellation()
        // Local fixtures are opt-in and never enabled by the application.
        if url.isFileURL {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumSize else { throw UpdateError.badResponse }
            try FileManager.default.copyItem(at: url, to: destination)
            progress(Int64(size), Int64(size))
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                let cancelled = self.cancelled
                lock.unlock()
                if cancelled { finish(.failure(CancellationError())); return }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            self.lock.unlock()
            session.invalidateAndCancel()
            self.finish(.failure(CancellationError()))
        }
    }

    /// Resumes the waiting caller once; later calls do nothing.
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.response?.url, ReleaseFeed.isAllowed(url) else {
            finish(.failure(UpdateError.insecureURL)); return
        }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateError.download("HTTP \(http.statusCode)")))
            return
        }
        do {
            guard Int64(try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumSize else { throw UpdateError.badResponse }
            try? FileManager.default.removeItem(at: destination)
            // The system deletes `location` when this method returns.
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch let error as UpdateError {
            finish(.failure(error))
        } catch {
            finish(.failure(UpdateError.download(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumSize || totalBytesExpectedToWrite > maximumSize {
            downloadTask.cancel()
            finish(.failure(UpdateError.badResponse))
            return
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ReleaseFeed.isAllowed(url) else {
            completionHandler(nil)
            finish(.failure(UpdateError.insecureURL))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            finish(.failure(UpdateError.download("no file")))
            return
        }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(UpdateError.download(error.localizedDescription)))
        }
    }
}
