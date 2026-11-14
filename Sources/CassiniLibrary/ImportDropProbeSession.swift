// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Foundation

/// Drag-hover content probe for one drag session.
///
/// `draggingEntered` / `draggingUpdated` run on the main actor and must never touch the
/// filesystem: `open`/`fstat`/`fstatfs`/`read` on a stalled network mount (or a slow local
/// disk) can block indefinitely, and `O_NONBLOCK` does not make regular-file I/O asynchronous.
/// `resolution(for:)` is a pure in-memory lookup that returns immediately; the header probe
/// runs off the main actor, its result is cached for the drag session, and `onResolved` fires
/// on the main actor so the overlay can update. Superseded or reset sessions never deliver.
@MainActor
public final class ImportDropProbeSession {
    public enum Resolution: Equatable, Sendable {
        /// The off-main probe has not finished yet; callers fall back to extension-only classification.
        case pending
        /// The probe finished; `supported` is the subset of probed URLs that passed.
        case resolved(supported: [URL])
    }

    public typealias Probe = @Sendable (URL) async -> Bool

    private let probe: Probe
    private var generation: UInt64 = 0
    private var urls: [URL] = []
    private var supported: [URL]?
    private var task: Task<Void, Never>?

    /// Called on the main actor when the current session's probe resolves.
    public var onResolved: (@MainActor () -> Void)?
    /// Test hook: called on the main actor when a superseded/reset session's probe completes and is discarded.
    var onStaleResultDiscarded: (@MainActor () -> Void)?

    public init(probe: @escaping Probe) {
        self.probe = probe
    }

    /// Non-blocking lookup. Starts (or supersedes) the session's probe when `urls` differ from
    /// the cached session; never performs I/O on the calling (main) actor.
    @discardableResult
    public func resolution(for urls: [URL]) -> Resolution {
        if urls != self.urls || (task == nil && supported == nil) {
            start(urls)
        }
        return supported.map { .resolved(supported: $0) } ?? .pending
    }

    /// Ends the drag session (`draggingExited` / `draggingEnded` / `concludeDragOperation`).
    /// Any in-flight probe is cancelled and its eventual result is discarded.
    public func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        urls = []
        supported = nil
    }

    private func start(_ urls: [URL]) {
        reset()
        self.urls = urls
        guard !urls.isEmpty else {
            supported = []
            return
        }
        let token = generation
        let probe = self.probe
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var passed: [URL] = []
            for url in urls {
                if Task.isCancelled { break }
                if await probe(url) { passed.append(url) }
            }
            await self?.finish(token: token, supported: passed)
        }
    }

    private func finish(token: UInt64, supported passed: [URL]) {
        guard token == generation else {
            onStaleResultDiscarded?()
            return
        }
        supported = passed
        task = nil
        onResolved?()
    }

    private nonisolated static let blockingProbeQueue = DispatchQueue(
        label: "cassini.import.drop-probe",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Wraps a blocking filesystem probe so it runs on a dedicated concurrent dispatch queue
    /// instead of the main actor or a Swift-concurrency cooperative thread (a stalled mount
    /// would otherwise pin a pool thread). A stalled call cannot be interrupted; its late
    /// result is simply discarded by generation once the drag session has moved on.
    public nonisolated static func blockingProbe(_ body: @escaping @Sendable (URL) -> Bool) -> Probe {
        { url in
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                blockingProbeQueue.async {
                    continuation.resume(returning: body(url))
                }
            }
        }
    }
}
