// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

/// A read task and the loaded session share this lease. Cancelling a window does
/// not revoke access while a non-cancellable file read is still unwinding.
final class FileAccessLease: @unchecked Sendable {
    let url: URL
    private let acquired: Bool
    init(_ url: URL) { self.url = url; acquired = url.startAccessingSecurityScopedResource() }
    deinit { if acquired { url.stopAccessingSecurityScopedResource() } }
}

@MainActor @Observable final class LegacyDocumentModel {
    let url: URL
    private(set) var session: SessionModel?
    @ObservationIgnored var onFailure: ((Error) -> Void)?
    @ObservationIgnored private var readTask: Task<CassiniDocument, Error>?
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var wantsPlay = false

    init(url: URL) { self.url = url.standardizedFileURL }
    func start() {
        guard !started else { return }; started = true; closed = false
        let registration = LegacyOpening.register(self)
        wantsPlay = registration.play
        let lease = registration.lease, url = registration.lease.url
        let read = Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(lease) {} }
            try Task.checkCancellation()
            let document = try CassiniDocument(url: url)
            try Task.checkCancellation()
            return document
        }
        readTask = read
        completion = Task { [weak self] in
            do {
                let document = try await read.value
                try Task.checkCancellation()
                guard let self, !self.closed else { return }
                let session = SessionModel(document: document, url: url, fileAccessLease: lease)
                self.session = session
                self.readTask = nil; self.completion = nil
                if self.wantsPlay { self.wantsPlay = false; session.player?.play() }
            } catch {
                guard !Task.isCancelled, let self, !self.closed else { return }
                self.readTask = nil; self.completion = nil
                self.onFailure?(error)
            }
        }
    }
    func requestPlay() {
        if let session { session.player?.play() }
        else { wantsPlay = true }
    }
    func close() {
        closed = true; started = false; wantsPlay = false
        readTask?.cancel(); readTask = nil
        completion?.cancel(); completion = nil
        session?.close(); session = nil
        onFailure = nil
        LegacyOpening.unregister(self)
    }
    deinit { readTask?.cancel(); completion?.cancel() }
}
