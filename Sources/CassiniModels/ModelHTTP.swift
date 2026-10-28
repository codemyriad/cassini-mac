// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// The delegate writes bounded chunks on one serial URLSession delegate queue.
/// No model-sized Data is retained in memory. Rejected headers never truncate
/// an existing partial file. Cancellation leaves only a validated-prefix partial.
enum ModelHTTP {
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.1.0"
        let safe = !version.isEmpty && version.utf8.count <= 64 && version.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }
        return "Cassini/" + (safe ? version : "0.1.0")
    }
    enum WriteMode { case replace, append, ignore }
    static func transfer(_ request: URLRequest, to file: URL, limit: UInt64,
                         progress: @escaping @Sendable (UInt64) -> Void = { _ in },
                         headers: @escaping @Sendable (HTTPURLResponse) throws -> WriteMode) async throws -> HTTPURLResponse {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let delegate = Transfer(file:file,limit:limit,progress:progress,headers:headers,continuation:continuation)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpAdditionalHeaders = ["User-Agent":userAgent]
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.urlCache = nil; configuration.urlCredentialStorage = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 3600
                configuration.httpMaximumConnectionsPerHost = 2
                let session = URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil)
                delegate.session = session
                let task = session.dataTask(with:request); cancellation.install(task); task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func install(_ task: URLSessionTask) {
            lock.lock(); self.task = task; let cancelled = cancelled; lock.unlock()
            if cancelled { task.cancel() }
        }
        func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    }
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let file: URL, limit: UInt64
        let reportProgress: @Sendable (UInt64) -> Void
        let headers: @Sendable (HTTPURLResponse) throws -> WriteMode
        let continuation: CheckedContinuation<HTTPURLResponse,Error>
        var session: URLSession?
        var output: FileHandle?
        var received: UInt64 = 0
        var response: HTTPURLResponse?
        var failure: Error?
        var ignored = false
        init(file: URL, limit: UInt64, progress: @escaping @Sendable (UInt64) -> Void, headers: @escaping @Sendable (HTTPURLResponse) throws -> WriteMode, continuation: CheckedContinuation<HTTPURLResponse,Error>) {
            self.file = file; self.limit = limit; self.reportProgress = progress; self.headers = headers; self.continuation = continuation
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            failure = ModelDownloadError.origin; completionHandler(nil)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            do {
                guard let response = response as? HTTPURLResponse,
                      response.value(forHTTPHeaderField:"Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else { throw ModelDownloadError.response }
                self.response = response
                let mode = try headers(response)
                if case .ignore = mode { ignored = true; completionHandler(.allow); return }
                let descriptor = open(file.path,O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,0o600)
                guard descriptor >= 0 else { throw POSIXError(.EACCES) }
                let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
                var info = stat()
                guard fstat(descriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { try? handle.close(); throw ModelDownloadError.unsafePath }
                if case .replace = mode { try handle.truncate(atOffset:0) }
                received = try handle.seekToEnd()
                guard received <= limit else { try? handle.close(); throw ModelDownloadError.tooLarge }
                output = handle; reportProgress(received); completionHandler(.allow)
            } catch { failure = error; completionHandler(.cancel) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil, !ignored else { return }
            do {
                guard UInt64(data.count) <= limit - received else { throw ModelDownloadError.tooLarge }
                try output?.write(contentsOf:data); received += UInt64(data.count); reportProgress(received)
            } catch { failure = error; dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            do { try output?.synchronize(); try output?.close() } catch { if failure == nil { failure = error } }
            if let error = failure ?? error { continuation.resume(throwing:error) }
            else if let response { continuation.resume(returning:response) }
            else { continuation.resume(throwing:ModelDownloadError.response) }
            self.session = nil; session.finishTasksAndInvalidate()
        }
    }
}
