import Foundation
import CoreServices
import CassiniLibrary

/// FSEvents invalidates the snapshot; it is not a second source of Library metadata.
/// File-level events cover atomic metadata replacement and capture WAV appends.
public final class LibraryWatcher: LibraryWatching, @unchecked Sendable {
    private final class Callback: @unchecked Sendable {
        let root: URL
        let action: @Sendable (URL) -> Void
        init(root: URL, action: @escaping @Sendable (URL) -> Void) { self.root = root; self.action = action }
    }
    public let root: URL
    private let queue = DispatchQueue(label: "com.codemyriad.cassini.library-watch")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    public init(root: URL) { self.root = root }
    public func start(onChange: @escaping @Sendable (URL) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }
        var ancestor = root
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        let callback = Callback(root: root, action: onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(), retain: { raw in
            guard let raw else { return nil }; _ = Unmanaged<Callback>.fromOpaque(raw).retain(); return UnsafeRawPointer(raw)
        }, release: { raw in
            if let raw { Unmanaged<Callback>.fromOpaque(raw).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, { _, raw, _, _, _, _ in
            guard let raw else { return }; let callback = Unmanaged<Callback>.fromOpaque(raw).takeUnretainedValue()
            callback.action(callback.root)
        }, &context, [ancestor.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { throw WatchError.unavailable }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); throw WatchError.unavailable }
        stream = created
    }
    public func stop() {
        lock.lock(); let previous = stream; stream = nil; lock.unlock()
        if let previous { FSEventStreamStop(previous); FSEventStreamInvalidate(previous); FSEventStreamRelease(previous) }
    }
    deinit { stop() }
    public enum WatchError: Error { case unavailable }
}
