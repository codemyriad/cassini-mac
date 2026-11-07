// SPDX-License-Identifier: GPL-3.0-or-later
#if SPECTROGRAM_PROBE
import AppKit
import QuartzCore
import Darwin

/// A single bounded observation of real renderer/workspace events. The deadline
/// only fails the observation; elapsed time can never make it pass (E1).
@MainActor final class SpectrogramProbeEvent {
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadline: DispatchWorkItem?
    private var activation: NSObjectProtocol?
    private var fileEvents: DispatchSourceFileSystemObject?
    private weak var controller: RecordingSpectrogram?
    private var condition: (() -> Bool)?
    private enum Failure: Error { case timeout(String) }

    func wait(_ description: String, controller: RecordingSpectrogram, timeout: Double = 10,
              directory: URL? = nil, until condition: @escaping () -> Bool) async throws {
        precondition(continuation == nil)
        if condition() { return }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation; self.controller = controller; self.condition = condition
            if let directory {
                let fd = open(directory.path,O_EVTONLY)
                guard fd >= 0 else { finish(.failure(Failure.timeout("File event observer: " + description))); return }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:.write,queue:.main)
                source.setEventHandler { [self] in check() }
                source.setCancelHandler { close(fd) }
                fileEvents = source; source.resume()
            }
            controller.fixtureChanged = { [self] in check() }
            activation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [self] _ in MainActor.assumeIsolated { check() } }
            let deadline = DispatchWorkItem { [self] in finish(.failure(Failure.timeout(description))) }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now()+timeout, execute: deadline)
            check()
        }
    }
    private func check() { if condition?() == true { finish(.success(())) } }
    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil; condition = nil; controller?.fixtureChanged = nil; controller = nil
        deadline?.cancel(); deadline = nil; fileEvents?.cancel(); fileEvents = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil; continuation.resume(with: result)
    }
    /// CA completion is the fade's actual completion, including Reduced Motion's
    /// empty transaction. The timeout is solely a failure bound.
    static func transaction(_ changes: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            let deadline = DispatchWorkItem {
                guard !completed else { return }; completed = true
                continuation.resume(throwing: Failure.timeout("Stop fade transaction"))
            }
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    guard !completed else { return }; completed = true; deadline.cancel()
                    continuation.resume()
                }
            }
            changes(); CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now()+5, execute: deadline)
        }
    }
}
#endif
