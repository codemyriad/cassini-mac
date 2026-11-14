// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Owns permission, recording and worker tasks. Cleanup runs immediately on cancel;
/// a cancelled task finishing later cannot clean up a newer enrollment.
@MainActor public final class VoiceEnrollmentOperation {
    private var task:Task<Void,Never>?
    private var id=UUID()
    private var cleanup:(() -> Void)?
    private var recordingCleanup:(() -> Void)?
    public init() {}
    public func cancel() {
        id=UUID();task?.cancel();task=nil
        let finish=cleanup;cleanup=nil;finish?()
        let stop=recordingCleanup;recordingCleanup=nil;stop?()
    }
    @discardableResult public func requestPermission(
        request:@escaping () async -> Bool,
        granted:@escaping () throws -> Void,
        denied:@escaping () -> Void,
        stopRecording:@escaping () -> Void = {},
        failed:@escaping (Error) -> Void
    ) -> Task<Void,Never> {
        start { [self] in
            let allowed=await request()
            guard !Task.isCancelled else { return }
            if !allowed { denied();return }
            do { try granted();recordingCleanup=stopRecording } catch { stopRecording();failed(error) }
        }
    }
    @discardableResult public func infer<Input,Output>(
        read:@escaping () async throws -> Input,
        worker:@escaping (Input) async throws -> Output,
        ready:@escaping (Output) -> Void,
        failed:@escaping (Error) -> Void,
        cleanup:@escaping () -> Void
    ) -> Task<Void,Never> {
        start(cleanup:cleanup) {
            do {
                let input=try await read()
                try Task.checkCancellation()
                let result=try await worker(input)
                try Task.checkCancellation()
                ready(result)
            } catch { if !Task.isCancelled { failed(error) } }
        }
    }
    @discardableResult public func start(cleanup:@escaping () -> Void = {}, operation:@escaping @MainActor () async -> Void) -> Task<Void,Never> {
        cancel()
        let token=UUID();id=token;self.cleanup=cleanup
        let running=Task {
            await operation()
            guard self.id == token else { return }
            self.task=nil
            let finish=self.cleanup;self.cleanup=nil;finish?()
        }
        task=running
        return running
    }
}

public enum VoiceEnrollmentWork {
    /// Detached CPU/I/O work needs an explicit link to its caller's cancellation.
    public static func run<T:Sendable>(_ operation:@escaping @Sendable () throws -> T) async throws -> T {
        let child=Task.detached(priority:.userInitiated,operation:operation)
        return try await withTaskCancellationHandler {
            let result=try await child.value
            try Task.checkCancellation()
            return result
        } onCancel: { child.cancel() }
    }
}
