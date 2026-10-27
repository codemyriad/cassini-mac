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
    var now: Date?
    var timeZone = TimeZone.current
    var activity: [UUID: CaptureActivity] = [:]
    var screenshot = false
    var scansLibrary = true
    static var current: Self {
        var context = Self()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { ["--whistle-self-test", "--recording-self-test", "--recording-sink-self-test"].contains($0) }) ||
            ["window", "sheet"].contains(argument("-CassiniScreenshot") ?? "") {
            context.scansLibrary = false
        }
        if ProcessInfo.processInfo.environment["CASSINI_HOSTED_SCREENSHOTS"] == "1",
           let name = argument("-CassiniScreenshot"), ["library", "first-run", "meeting", "record-first"].contains(name),
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
        return context
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
    let context: LibraryLaunchContext
    private(set) var snapshot: LibraryScan?
    var selectedKey: String?
    private(set) var loaded = false
    private(set) var revision = 0
    private(set) var offline = false
    @ObservationIgnored private let activity: NativeActivity
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private let watcher: LibraryWatcher
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pending = Set<URL>()
    @ObservationIgnored private var scanning = false
    var meetings: [LibraryMeeting] { snapshot?.meetings ?? [] }
    var groups: [LibraryDayGroup] { snapshot?.groups(format: format) ?? [] }
    var selected: LibraryMeeting? { meetings.first { $0.libraryKey == selectedKey } }
    var format: LibraryFormat { .init(timeZone: context.timeZone, now: context.now ?? Date()) }
    init(context: LibraryLaunchContext = .current) {
        self.context = context
        let activity = NativeActivity(context.activity); self.activity = activity
        scanner = LibraryScanner(root: context.root, activity: activity)
        watcher = LibraryWatcher(root: context.root)
    }
    func start() {
        guard context.scansLibrary else { loaded = true; return }
        guard !started else { return }; started = true
        if !context.screenshot { observeNativeRecorder() }
        do { try watcher.start { [weak self] folder in Task { @MainActor in self?.refresh(affected: folder) } } }
        catch { /* A snapshot remains useful if monitoring is unavailable. */ }
        refresh()
    }
    func stop() { started = false; watcher.stop(); pending.removeAll() }
    func refresh(affected: URL? = nil) {
        pending.insert(affected ?? context.root)
        guard !scanning else { return }; scanning = true
        Task {
            while started, !pending.isEmpty {
                let target: URL
                if pending.contains(context.root) { target = context.root; pending.removeAll() }
                else { target = pending.sorted { $0.path < $1.path }.first!; pending.remove(target) }
                do {
                    let result = try await scanner.scanInBackground(affected: target, now: context.now ?? Date())
                    guard started else { break }
                    snapshot = result; offline = false
                    LegacyOpening.refreshTranscripts(result.meetings)
                    if selectedKey == nil || !meetings.contains(where: { $0.libraryKey == selectedKey }) {
                        selectedKey = context.screenshot ? meetings.first(where: { $0.title == "Budget review" })?.libraryKey ?? meetings.first?.libraryKey : meetings.first?.libraryKey
                    }
                } catch { offline = true }
                loaded = true; revision &+= 1
            }
            scanning = false
        }
    }
    private func observeNativeRecorder() {
        guard started else { return }
        let recorder = RecordingController.shared
        var phases: [UUID: CaptureActivity] = [:]
        withObservationTracking {
            if recorder.isRecording || recorder.isSaving, let folder = recorder.directory,
               let id = UUID(uuidString: String(folder.lastPathComponent.dropFirst("Recording-".count))) { phases[id] = recorder.isSaving ? .saving : .recording }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.observeNativeRecorder()
            }
        }
        if recorder.isRecording, let folder = recorder.directory, !activity.snapshot().keys.contains(where: { $0.uuidString.lowercased() == String(folder.lastPathComponent.dropFirst("Recording-".count)) }) {
            selectedKey = folder.lastPathComponent
        }
        let changedIDs = Set(activity.snapshot().keys).union(phases.keys)
        activity.replace(phases)
        for id in changedIDs { refresh(affected: context.root.appendingPathComponent("Recording-" + id.uuidString.lowercased())) }
    }
    func excerpt(_ meeting: LibraryMeeting) -> [LibraryTranscriptTurn] { Array(meeting.transcriptTurns.prefix(3)) }
}
