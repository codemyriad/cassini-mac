// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import CassiniLibrary
import CassiniLibraryWatchers
import Observation

struct LibraryLaunchContext {
    var root: URL = {
        // NSHomeDirectory may be the app container; the contract is the user's
        // literal Music/Cassini, shared with the unsandboxed browser hosts.
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { URL(fileURLWithPath: String(cString: $0)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Music/Cassini")
    }()
    var previousRoots: [URL] = []
    var locationProblem: String?
    var now: Date?
    var timeZone = TimeZone.current
    var activity: [UUID: CaptureActivity] = [:]
    var screenshot = false
    var scansLibrary = true
    static var current: Self {
        var context = Self()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { ["--whistle-self-test", "--recording-self-test", "--recording-sink-self-test", "--export-self-test"].contains($0) }) ||
            ["window", "sheet"].contains(argument("-CassiniScreenshot") ?? "") {
            context.scansLibrary = false
        }
        if ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
           let name = argument("-CassiniScreenshot"), ["library", "first-run", "meeting", "record-first", "recording", "received", "export", "search", "settings-recording", "settings-transcription"].contains(name),
           let path = argument("-CassiniFixture"), let clock = argument("-CassiniNow"),
           let date = ISO8601DateFormatter().date(from: clock) {
            context.root = URL(fileURLWithPath: path).appendingPathComponent("root")
            context.now = date; context.timeZone = TimeZone(identifier: "Europe/Rome")!; context.screenshot = true
            if let bytes = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("activity.json")),
               let phases = try? JSONDecoder().decode([String: String].self, from: bytes) {
                for (id, phase) in phases { if let id = UUID(uuidString: id) { context.activity[id] = phase == "saving" ? .saving : .recording } }
            }
        }
        #endif
        #if DEBUG
        if let root = RecordingFixture.root { context.root = root; context.screenshot = false; context.now = nil }
        #endif
        if context.scansLibrary {
            do {
                let location = try LibraryLocation.read(file:locationFile,defaultRoot:context.root)
                context.root = location.primary; context.previousRoots = Array(location.roots.dropFirst())
            } catch { context.locationProblem = error.localizedDescription }
        }
        return context
    }
    static var locationFile: URL {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1" {
            let id = SettingsFixture.id?.uuidString ?? argument("-CassiniCaptureID").flatMap { UUID(uuidString:$0)?.uuidString } ?? String(ProcessInfo.processInfo.processIdentifier)
            return FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSettingsFixture-" + id + "/library-location.json")
        }
        #endif
        return LibraryLocation.standardFile
    }
    static func argument(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
private final class NativeActivity: CaptureActivityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [UUID: CaptureActivity]
    init(_ phases: [UUID: CaptureActivity]) { self.phases = phases }
    func replace(_ phases: [UUID: CaptureActivity]) { lock.lock(); self.phases = phases; lock.unlock() }
    func snapshot() -> [UUID: CaptureActivity] { lock.lock(); defer { lock.unlock() }; return phases }
}
@MainActor @Observable
final class LibraryStore {
    static let shared = LibraryStore()
    private(set) var context: LibraryLaunchContext
    private(set) var snapshot: LibraryScan?
    var selectedKey: String?
    private(set) var loaded = false
    private(set) var revision = 0
    private(set) var offline = false
    @ObservationIgnored private let activity: NativeActivity
    @ObservationIgnored private var scanners: [URL:LibraryScanner] = [:]
    @ObservationIgnored private var watchers: [LibraryWatcher] = []
    @ObservationIgnored private var rootSnapshots: [URL:LibraryScan] = [:]
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pending = Set<URL>()
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var selectionWhenAvailable: String?
    @ObservationIgnored private var selectionFolderWhenAvailable: URL?
    var meetings: [LibraryMeeting] { snapshot?.meetings ?? [] }
    var groups: [LibraryDayGroup] { snapshot?.groups(format: format) ?? [] }
    var selected: LibraryMeeting? { meetings.first { $0.libraryKey == selectedKey } }
    var format: LibraryFormat { .init(timeZone: context.timeZone, now: context.now ?? Date()) }
    init(context: LibraryLaunchContext = .current) {
        self.context = context
        let activity = NativeActivity(context.activity); self.activity = activity
        for root in [context.root] + context.previousRoots { scanners[root] = LibraryScanner(root:root,activity:activity) }
    }
    func start() {
        guard context.scansLibrary else { loaded = true; return }
        guard !started else { return }; started = true
        guard context.locationProblem == nil else { loaded = true; offline = true; revision &+= 1; return }
        if !context.screenshot { observeNativeRecorder() }
        for root in [context.root] + context.previousRoots {
            let watcher = LibraryWatcher(root:root); watchers.append(watcher)
            do { try watcher.start { [weak self] folder in Task { @MainActor in self?.refresh(affected:folder) } } }
            catch { /* A read-only snapshot remains useful. */ }
        }
        refresh()
    }
    func stop() { started = false; epoch &+= 1; watchers.forEach { $0.stop() }; watchers = []; pending.removeAll(); scanning = false }
    func reloadLocation() {
        let selection = selected
        let folder = selectionFolderWhenAvailable ?? selection.map { LibraryLocation.canonical($0.folder) }
        selectionFolderWhenAvailable = folder
        selectionWhenAvailable = folder?.lastPathComponent
        stop(); LibraryLocationModel.shared.reload(); context = LibraryLocationModel.shared.context()
        scanners = [:]; rootSnapshots = [:]; loaded = false
        for root in [context.root] + context.previousRoots { scanners[root] = LibraryScanner(root:root,activity:activity) }
        selectedKey = selection?.libraryKey ?? selectedKey; start()
    }
    @discardableResult func selectImported(_ meeting: LibraryMeeting) -> LibraryMeeting {
        let folder = LibraryLocation.canonical(meeting.folder)
        // A restored/readable retained folder may not be in the last watcher
        // snapshot. Apply the same collision rule as a full scan to fresh input.
        let others = meetings.filter { LibraryLocation.canonical($0.folder) != folder }
        let retained = Set(LibraryLocationModel.shared.location.pendingMoves.map { LibraryLocation.canonical(URL(fileURLWithPath:$0.id)) })
        let displayed = LibraryScan.merging([.init(meetings:others,issues:[]),.init(meetings:[meeting],issues:[])],retaining:retained)
            .meetings.first { LibraryLocation.canonical($0.folder) == folder } ?? meeting
        selectionFolderWhenAvailable = folder; selectionWhenAvailable = nil
        selectedKey = displayed.libraryKey
        refresh(affected:meeting.folder)
        return displayed
    }
    func refresh(affected: URL? = nil) {
        pending.insert(affected ?? context.root)
        guard !scanning else { return }; scanning = true
        let generation = epoch
        Task {
            while started, generation == epoch, !pending.isEmpty {
                let target: URL
                if pending.contains(context.root) { target = context.root; pending.removeAll() }
                else { target = pending.sorted { $0.path < $1.path }.first!; pending.remove(target) }
                var primaryFailed = false
                for root in [context.root] + context.previousRoots {
                    guard let scanner = scanners[root], target == context.root || target.path == root.path || target.deletingLastPathComponent().path == root.path else { continue }
                    do {
                        let result = try await scanner.scanInBackground(affected:target == context.root ? nil : target,now:context.now ?? Date())
                        guard started, generation == epoch else { return }
                        rootSnapshots[root] = result
                    } catch { if root == context.root { primaryFailed = true } }
                }
                guard started, generation == epoch else { return }
                let retained = Set(LibraryLocationModel.shared.location.pendingMoves.map { LibraryLocation.canonical(URL(fileURLWithPath:$0.id)) })
                let result = LibraryScan.merging(([context.root] + context.previousRoots).compactMap { rootSnapshots[$0] },retaining:retained)
                snapshot = result; offline = primaryFailed
                if let folder = selectionFolderWhenAvailable,
                   let selected = result.meetings.first(where:{ LibraryLocation.canonical($0.folder) == folder }) {
                    selectedKey = selected.libraryKey; selectionFolderWhenAvailable = nil; selectionWhenAvailable = nil
                } else if let key = selectionWhenAvailable, result.meetings.contains(where:{ $0.libraryKey == key }) {
                    selectedKey = key; selectionWhenAvailable = nil; selectionFolderWhenAvailable = nil
                }
                TranscriptionQueue.shared.consider(result.meetings,automatic:!context.screenshot && (!RecordingFixture.enabled || RecordingFixture.transcribes))
                LegacyOpening.refreshTranscripts(result.meetings)
                if selectedKey == nil || !meetings.contains(where:{ $0.libraryKey == selectedKey }) {
                    selectedKey = context.screenshot ? meetings.first(where:{ $0.title == "Budget review" })?.libraryKey ?? meetings.first?.libraryKey : meetings.first?.libraryKey
                }
                loaded = true; revision &+= 1
                LibraryMoveCoordinator.shared.maybeRetryDeferred()
            }
            if generation == epoch { scanning = false }
        }
    }
    private func observeNativeRecorder() {
        guard started else { return }
        let recorder = RecordingController.shared
        var phases: [UUID: CaptureActivity] = [:]
        let generation = epoch
        withObservationTracking {
            if recorder.isRecording || recorder.isSaving, let folder = recorder.directory,
               let id = UUID(uuidString: String(folder.lastPathComponent.dropFirst("Recording-".count))) { phases[id] = recorder.isSaving ? .saving : .recording }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started, self.epoch == generation else { return }
                self.observeNativeRecorder()
            }
        }
        if recorder.isRecording, let folder = recorder.directory, !activity.snapshot().keys.contains(where: { $0.uuidString.lowercased() == String(folder.lastPathComponent.dropFirst("Recording-".count)) }) {
            selectedKey = folder.lastPathComponent
        }
        let changedIDs = Set(activity.snapshot().keys).union(phases.keys)
        activity.replace(phases)
        for id in changedIDs {
            for root in [context.root] + context.previousRoots { refresh(affected:root.appendingPathComponent("Recording-" + id.uuidString.lowercased())) }
        }
    }
    func excerpt(_ meeting: LibraryMeeting) -> [LibraryTranscriptTurn] { Array(meeting.transcriptTurns.prefix(3)) }
}
