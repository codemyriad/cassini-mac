// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniModels
import Darwin

private final class ModelDirectoryAccess {
    let url: URL
    private let started: Bool
    init(_ bookmark: Data) throws {
        var stale = false
        url = try URL(resolvingBookmarkData:bookmark,options:[.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
        guard url.isFileURL else { throw ModelDownloadError.unsafePath }
        started = url.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

final class ModelDownloadConnection: NSObject, CassiniModelDownloadService, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var operation: (id: UUID, task: Task<Void,Never>)?
    private var progressBucket = -1
    init(_ connection: NSXPCConnection) { self.connection = connection }
    func cancel() { lock.lock(); let task = operation?.task; lock.unlock(); task?.cancel() }
    func install(destinationBookmark: Data, expectedDirectory: String, reply: @escaping @Sendable (String?,NSError?) -> Void) {
        lock.lock()
        guard operation == nil else { lock.unlock(); reply(nil,Self.failure(ModelDownloadError.busy)); return }
        let id = UUID(); progressBucket = -1
        let work = Task { [weak self] in
            guard let self else { return }
            let result: Result<URL,Error>
            do {
                let access = try ModelDirectoryAccess(destinationBookmark)
                let root = access.url
                guard root.resolvingSymlinksInPath().path == expectedDirectory else { throw ModelDownloadError.unsafePath }
                defer { withExtendedLifetime(access) {} }
                let downloader = ModelDownloader(appData:root)
                result = .success(try await downloader.install(.parakeetUltra) { [weak self] progress in self?.send(progress) })
            } catch { result = .failure(error) }
            finish(id)
            switch result {
            case .success(let url): reply(url.path,nil)
            case .failure(let error): reply(nil,Self.failure(error))
            }
        }
        operation = (id,work); lock.unlock()
    }
    private func finish(_ id: UUID) { lock.lock(); if operation?.id == id { operation = nil }; lock.unlock() }
    private func send(_ value: ModelDownloadProgress) {
        let bucket = Int(value.fraction * 100)
        lock.lock(); let changed = progressBucket != bucket || value.isInstalled
        progressBucket = bucket; lock.unlock()
        guard changed else { return }
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? CassiniModelDownloadProgress)?
            .progress(received:value.receivedBytes,total:value.totalBytes,installed:value.isInstalled)
    }
    private static func failure(_ error: Error) -> NSError {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return NSError(domain:NSCocoaErrorDomain,code:NSUserCancelledError) }
        var info: [String:Any] = [NSLocalizedDescriptionKey:String(describing:error)], code = 0
        if case ModelDownloadError.diskSpace(let required,let available) = error {
            code = 1; info["required"] = NSNumber(value:required); info["available"] = NSNumber(value:available)
        }
        return NSError(domain:"io.codemyriad.cassini.model-download",code:code,userInfo:info)
    }
    #if DEBUG
    func probeEnvironment(port: UInt16, destinationBookmark: Data, expectedDirectory: String, reply: @escaping @Sendable (Bool,Bool,NSError?) -> Void) {
        do {
            let access = try ModelDirectoryAccess(destinationBookmark)
            guard access.url.resolvingSymlinksInPath().path == expectedDirectory else { throw NSError(domain:"ModelScopeProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"Bookmark resolved to another directory", "resolved":access.url.path,"expected":expectedDirectory]) }
            defer { withExtendedLifetime(access) {} }
            let file = access.url.appendingPathComponent(".model-scope-probe")
            defer { try? FileManager.default.removeItem(at:file) }
            try Data("probe".utf8).write(to:file,options:.atomic)
            let scoped = try Data(contentsOf:file) == Data("probe".utf8)
            let fd = socket(AF_INET,SOCK_STREAM,0)
            guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            reply(result == 0,scoped,nil)
        } catch { reply(false,false,Self.failure(error)) }
    }
    #endif
}
final class ModelDownloadListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = ModelDownloadConnection(connection)
        connection.exportedInterface = NSXPCInterface(with:CassiniModelDownloadService.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with:CassiniModelDownloadProgress.self)
        connection.invalidationHandler = { [weak service] in service?.cancel() }
        connection.interruptionHandler = { [weak service] in service?.cancel() }
        connection.resume(); return true
    }
}
