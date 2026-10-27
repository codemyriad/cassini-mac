import Foundation
import CoreServices
import CassiniLibrary

/// R10: metadata events invalidate one meeting, root events the complete snapshot.
/// PCM appends are deliberately ignored. Callbacks are delivered off the UI thread.
public final class LibraryWatcher: LibraryWatching, @unchecked Sendable {
    private final class Callback {
        weak var owner: LibraryWatcher?
        init(_ owner: LibraryWatcher) { self.owner = owner }
    }
    public let root: URL
    private let queue = DispatchQueue(label: "com.codemyriad.cassini.library-watch")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var handler: (@Sendable (URL) -> Void)?
    private var timer: DispatchWorkItem?
    private var batch = ChangeBatch()
    public init(root: URL) {
        self.root = URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: false)
        queue.setSpecific(key: queueKey, value: true)
    }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }
    public func start(onChange: @escaping @Sendable (URL) -> Void) throws {
        try synchronized {
            guard handler == nil else { return }
            handler = onChange
            do { try install() } catch { handler = nil; throw error }
        }
    }
    private func install() throws {
        var ancestor = root.resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        var paths = [ancestor.path]
        // Follow a linked root while retaining notification of replacement of the link.
        if root.resolvingSymlinksInPath().path != root.path { paths.append(root.deletingLastPathComponent().path) }
        guard paths != watched || stream == nil else { return }
        let callback = Callback(self)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(), retain: { raw in
            guard let raw else { return nil }
            _ = Unmanaged<Callback>.fromOpaque(raw).retain(); return UnsafeRawPointer(raw)
        }, release: { raw in
            if let raw { Unmanaged<Callback>.fromOpaque(raw).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(nil, { _, raw, count, rawPaths, eventFlags, _ in
            guard let raw else { return }
            let callback = Unmanaged<Callback>.fromOpaque(raw).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            callback.owner?.receive(paths: paths, flags: (0..<count).map { eventFlags[$0] })
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { throw WatchError.unavailable }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created); throw WatchError.unavailable
        }
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = created; watched = paths
    }
    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard handler != nil else { return }
        var changed = false
        let resolved = URL(fileURLWithPath: root.resolvingSymlinksInPath().path, isDirectory: false)
        for (path, flags) in zip(paths, flags) {
            let event = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            if let target = Self.target(event, flags: flags, root: resolved) ?? Self.target(event, flags: flags, root: root) {
                let mapped = target.path == resolved.path || target.path == root.path ? root : resolved.appendingPathComponent(target.lastPathComponent)
                batch.add(mapped, root: root, now: ProcessInfo.processInfo.systemUptime); changed = true
            }
        }
        // Rebind an ancestor watch when a missing root is created (or removed).
        queue.async { [weak self] in
            guard let self, self.handler != nil else { return }
            do { try self.install() } catch { self.handler?(self.root) }
        }
        guard changed, let deadline = batch.deadline else { return }
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let urls = self.batch.take()
            for url in urls { self.handler?(url) }
        }
        timer = work
        queue.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }
    static func target(_ path: URL, flags: FSEventStreamEventFlags, root: URL) -> URL? {
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
        if flags & dropped != 0 { return root }
        let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        if path.path == root.path { return root }
        if root.path.hasPrefix(path.path + "/") { return flags & structural != 0 ? root : nil }
        guard path.path.hasPrefix(root.path + "/") else { return nil }
        let relative = String(path.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
        guard let name = relative.first, canonicalMeeting(name) else { return nil }
        let folder = root.appendingPathComponent(name)
        if relative.count == 1 { return flags & structural != 0 ? folder : nil }
        guard relative.count == 2 else { return nil }
        let file = relative[1]
        if ["session.json", "meeting.json", "transcript.json"].contains(file) || (name.hasPrefix("Received-") && file.hasSuffix(".opus")) { return folder }
        return nil
    }
    private static func canonicalMeeting(_ name: String) -> Bool {
        let received = name.hasPrefix("Received-")
        guard received || name.hasPrefix("Recording-") else { return false }
        let text = String(name.dropFirst(received ? 9 : 10))
        return UUID(uuidString: text)?.uuidString.lowercased() == text
    }
    public func stop() {
        synchronized {
            handler = nil; timer?.cancel(); timer = nil; batch = ChangeBatch()
            if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
            stream = nil; watched = []
        }
    }
    deinit { stop() }
    public enum WatchError: Error { case unavailable }
}
/// A deterministic debounce policy, tested without wall-clock sleeps.
struct ChangeBatch {
    private var urls: Set<URL> = []
    private var first: TimeInterval?
    private(set) var deadline: TimeInterval?
    mutating func add(_ url: URL, root: URL, now: TimeInterval) {
        if first == nil { first = now }
        if url.path == root.path { urls = [root] }
        else if !urls.contains(root) { urls.insert(url) }
        deadline = min(now + 0.250, first! + 2)
    }
    mutating func take() -> [URL] {
        let result = urls.sorted { $0.path < $1.path }
        urls = []; first = nil; deadline = nil
        return result
    }
}
