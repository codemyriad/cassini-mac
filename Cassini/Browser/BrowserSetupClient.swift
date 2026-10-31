// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniBrowserSetup

/// Transfers only the two bundled file grants to the separately sandboxed
/// installer. The helper rechecks both against its own containing app.
final class BrowserSetupClient: @unchecked Sendable {
    private let lock = NSLock()
    private let connection = NSXPCConnection(serviceName:BrowserSetupInstallation.serviceName)
    private var pending: CheckedContinuation<Void,Error>?
    private var finished = false
    func connect() async throws {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let bookmarks = try await Task.detached(priority:.utility) {
            try ["cassini-browser-host","cassini-control-host"].map {
                try contents.appendingPathComponent("MacOS/" + $0).bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
            }
        }.value
        try await perform { proxy in
            proxy.connect(audioHostBookmark:bookmarks[0],controlHostBookmark:bookmarks[1]) { [weak self] count,error in
                if let error { self?.finish(.failure(error)) }
                else if count > 0 { self?.finish(.success(())) }
                else { self?.finish(.failure(BrowserSetupError.unavailable)) }
            }
        }
    }
    func prepareCompanion() async throws {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BrowserCompanion")
        let bookmark = try await Task.detached(priority:.utility) {
            try source.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
        }.value
        try await perform { proxy in
            proxy.prepareCompanion(bookmark:bookmark) { [weak self] error in
                self?.finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }
    private func perform(_ invoke: (CassiniBrowserSetupService) -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                lock.lock()
                guard !finished, pending == nil else { lock.unlock(); continuation.resume(throwing:CancellationError()); return }
                pending = continuation; lock.unlock()
                connection.remoteObjectInterface = NSXPCInterface(with:CassiniBrowserSetupService.self)
                connection.invalidationHandler = { [weak self] in self?.finish(.failure(BrowserSetupError.unavailable)) }
                connection.interruptionHandler = { [weak self] in self?.finish(.failure(BrowserSetupError.unavailable)) }
                connection.resume()
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in self?.finish(.failure(error)) }) as? CassiniBrowserSetupService else { finish(.failure(BrowserSetupError.unavailable)); return }
                invoke(proxy)
                DispatchQueue.global().asyncAfter(deadline:.now() + 30) { [weak self] in self?.finish(.failure(BrowserSetupError.unavailable)) }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    private func finish(_ result: Result<Void,Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
        let pending = self.pending; self.pending = nil; lock.unlock()
        connection.invalidationHandler = nil; connection.interruptionHandler = nil
        connection.invalidate(); pending?.resume(with:result)
    }
}
