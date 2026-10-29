// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniModels

/// Networking belongs to the XPC service. The UI and its inference children
/// retain their sandbox's network denial. This object owns one install request.
final class ModelDownloadClient: NSObject, CassiniModelDownloadProgress, @unchecked Sendable {
    static let serviceName = "io.codemyriad.cassini.models"
    private let connection = NSXPCConnection(serviceName:serviceName)
    private let queue = DispatchQueue(label:"io.codemyriad.cassini.model-request")
    private let changed: @Sendable (Double) -> Void
    private var pending: CheckedContinuation<URL,Error>?
    private var cancelled = false
    private var finished = false
    init(progress: @escaping @Sendable (Double) -> Void) {
        changed = progress; super.init()
        connection.remoteObjectInterface = NSXPCInterface(with:CassiniModelDownloadService.self)
        connection.exportedInterface = NSXPCInterface(with:CassiniModelDownloadProgress.self)
        connection.invalidationHandler = { [weak self] in self?.finish(.failure(ModelDownloadError.response)) }
        connection.interruptionHandler = { [weak self] in self?.finish(.failure(ModelDownloadError.response)) }
    }
    func install(appData: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            let scope = try await Task.detached(priority:.utility) {
                try FileManager.default.createDirectory(at:appData,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let root = appData.resolvingSymlinksInPath()
                // Apple documents implicit security-scope bookmarks for sharing
                // a directory grant between an app and its separate XPC service.
                return (root,try root.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil))
            }.value
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !finished, pending == nil else { continuation.resume(throwing:ModelDownloadError.busy); return }
                    pending = continuation
                    guard !cancelled else { finish(.failure(CancellationError())); return }
                    connection.exportedObject = self
                    connection.resume()
                    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in self?.finish(.failure(error)) }) as? CassiniModelDownloadService else {
                        finish(.failure(ModelDownloadError.response)); return
                    }
                    proxy.install(destinationBookmark:scope.1,expectedDirectory:scope.0.path) { [weak self] path,error in
                        if let error { self?.finish(.failure(Self.decode(error))); return }
                        let pin = ModelPin.parakeetUltra
                        let expected = scope.0.appendingPathComponent("models/" + pin.id + "/" + pin.sourceSHA256)
                        guard let path, URL(fileURLWithPath:path).standardizedFileURL.path == expected.path else {
                            self?.finish(.failure(ModelDownloadError.installation)); return
                        }
                        self?.finish(.success(expected))
                    }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        queue.async { [self] in
            cancelled = true
            guard !finished, pending != nil else { return }
            (connection.remoteObjectProxyWithErrorHandler { [weak self] error in self?.finish(.failure(error)) } as? CassiniModelDownloadService)?.cancel()
        }
    }
    func progress(received: UInt64, total: UInt64, installed: Bool) {
        guard total > 0, received <= total else { return }
        queue.async { [self] in if !finished && !cancelled { changed(Double(received)/Double(total)) } }
    }
    private func finish(_ result: Result<URL,Error>) {
        queue.async { [self] in
            guard !finished, let pending else { return }; finished = true; self.pending = nil
            connection.invalidationHandler = nil; connection.interruptionHandler = nil; connection.exportedObject = nil
            connection.invalidate(); pending.resume(with:result)
        }
    }
    private static func decode(_ error: NSError) -> Error {
        if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError { return CancellationError() }
        if error.domain == "io.codemyriad.cassini.model-download", error.code == 1,
           let required = error.userInfo["required"] as? NSNumber, let available = error.userInfo["available"] as? NSNumber {
            return ModelDownloadError.diskSpace(required:required.uint64Value,available:available.uint64Value)
        }
        return error
    }
}
