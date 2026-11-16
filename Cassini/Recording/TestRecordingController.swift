// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation
import Observation
import CassiniLibrary
import CassiniPlayback
import CassiniRecording
import CassiniBrowserControl

/// D60 uses the same native admission, three-second first-buffer bounds and
/// writer as a meeting, with a private disposable destination and no Library hooks.
@MainActor @Observable final class TestRecordingController {
    static let shared = TestRecordingController()
    enum Phase { case idle, starting, recording, finishing, result }
    var presented = false
    private(set) var phase: Phase = .idle
    private(set) var problem: String?
    private(set) var heard: Set<CaptureSide> = []
    private(set) var refused: [CaptureSide:String] = [:]
    private(set) var playing = false
    var canStart: Bool { !RecordingOverview.active && !RecordingOverview.starting && !RecordingOverview.saving && phase == .idle }
    @ObservationIgnored private var owner: OwnedBrowserCapture?
    @ObservationIgnored private var input: CaptureInputLifecycle?
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeline: SessionTimeline?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cleanup: Task<Void,Never>?
    @ObservationIgnored var duration: @Sendable () async throws -> Void = { try await Task.sleep(for:.seconds(8)) }
    @ObservationIgnored var makeMicrophone: @MainActor () -> any CaptureInput = { MeetingMicrophoneInput() }
    @ObservationIgnored var makeSystem: @MainActor () -> any CaptureInput = { MeetingSystemInput() }
    @ObservationIgnored var changed: (() -> Void)?
    init() { cleanup = Task { await Self.sweep() } }
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Cassini-TestRecording",isDirectory:true) }

    #if DEBUG
    var fixtureDirectory: URL? { owner?.snapshot.directory }
    var playAutomatically = true
    #endif
    func start() {
        guard canStart || phase == .result else { return }
        let previous = cancel(close:false)
        let attempt = UUID(); generation = attempt
        phase = .starting; problem = nil; heard = []; refused = [:]
        SessionPlaybackController.stopAll(); PlayerController.pauseActive()
        task = Task {
            await previous.value
            guard generation == attempt else { return }
            do {
                let root = Self.root
                let title = UXText.text("test.action")
                let owner = try await Task.detached(priority:.userInitiated) {
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                    return try OwnedBrowserCapture(parent:root,title:title,microphone:true,browser:false,changed:{ _ in })
                }.value
                guard generation == attempt else {
                    await Self.remove(owner); return
                }
                self.owner = owner
                let input = CaptureInputLifecycle(capture:owner,originHostTime:mach_absolute_time(),
                    microphone:makeMicrophone,system:makeSystem,failure:{ [weak self] message in
                        Task { @MainActor in
                            guard let self, self.generation == attempt else { return }
                            self.problem = message
                        }
                    },refused:{ [weak self] side, refusal in
                        guard let self, self.generation == attempt else { return }
                        self.refused[side] = refusal.code; self.changed?()
                    },admission:{ [weak self] in self?.generation == attempt })
                self.input = input
                try await input.start()
                guard generation == attempt else { return }
                phase = .recording; changed?()
                meter = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sampleLevels() }
                }
                try await duration()
                guard generation == attempt else { return }
                sampleLevels(); meter?.invalidate(); meter = nil
                phase = .finishing
                try await input.stop()
                try await Task.detached(priority:.utility) { try owner.finish() }.value
                guard generation == attempt else { return }
                let snapshot = await Task.detached(priority:.utility) { owner.snapshot }.value
                let tracks = snapshot.manifest.tracks.map {
                    LibraryAudioTrack(url:snapshot.directory.appendingPathComponent($0.file),startOffsetMs:$0.startOffsetMs,frameCount:$0.frames,sampleRate:$0.sampleRate)
                }
                if tracks.contains(where:{ ($0.frameCount ?? 0) > 0 }) {
                    let prepared = try await SessionComposition.make(tracks:tracks)
                    guard generation == attempt else { return }
                    timeline = prepared
                }
                phase = .result
                #if DEBUG
                if playAutomatically { play() }
                #else
                play()
                #endif
                changed?()
            } catch is CancellationError {
            } catch {
                guard generation == attempt else { return }
                problem = error.localizedDescription
                let pending = cancel(close:false)
                await pending.value
                phase = .result; changed?()
            }
        }
    }
    private func sampleLevels() {
        guard let input else { return }
        for (side,status) in input.availableStatus() {
            if status?.levels.values.contains(where:{ $0 >= 0.01 }) == true { heard.insert(side) }
        }
    }
    func play() {
        guard let timeline else { return }
        stopPlayer()
        let item = AVPlayerItem(asset:timeline.asset)
        let player = AVPlayer(playerItem:item); self.player = player
        endObserver = NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.stopPlayer() }
        }
        playing = true; player.play()
    }
    private func stopPlayer() {
        player?.pause(); player?.replaceCurrentItem(with:nil); player = nil; playing = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
    }
    @discardableResult func cancel(close: Bool = true) -> Task<Void,Never> {
        generation = UUID(); task?.cancel(); task = nil
        meter?.invalidate(); meter = nil; stopPlayer(); timeline = nil
        let input = self.input, owner = self.owner, previous = cleanup
        self.input = nil; self.owner = nil; phase = .idle
        if close { presented = false }
        let next = Task {
            await previous?.value
            try? await input?.stop()
            if let owner { await Self.remove(owner) }
        }
        cleanup = next; changed?(); return next
    }
    private static func remove(_ owner: OwnedBrowserCapture) async {
        await Task.detached(priority:.utility) {
            try? owner.finish()
            try? FileManager.default.removeItem(at:owner.snapshot.directory)
        }.value
    }
    static func sweep() async {
        let root = root
        await Task.detached(priority:.utility) { try? FileManager.default.removeItem(at:root) }.value
    }
}
struct TestRecordingView: View {
    @State private var test = TestRecordingController.shared
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text(UXText.text("test.action")).font(.title2).fontWeight(.bold)
            Text(UXText.text("test.intro")).fixedSize(horizontal:false,vertical:true)
            if test.phase == .starting || test.phase == .recording || test.phase == .finishing {
                HStack { ProgressView().controlSize(.small); Text(UXText.text("test.running")) }
            }
            if test.phase == .result {
                ForEach([CaptureSide.me,.others],id:\.self) { side in
                    let stream = UXText.text(side == .me ? "common.yourMicrophone" : "recordFirst.sound.title")
                    Text(UXText.text(test.heard.contains(side) ? "test.result.working" : "test.result.silent",["stream":stream]))
                    if let refusal = test.refused[side] {
                        Text(UXText.text(refusal == CaptureRefusal.permissionDenied ? "details.sources.refused.permissionDenied" : "details.sources.refused.deviceUnavailable",["source":stream])).foregroundStyle(CassiniTheme.warnInk)
                    }
                }
                Text(UXText.text("test.note")).foregroundStyle(CassiniTheme.ink2)
            }
            if let problem = test.problem { Text(problem).foregroundStyle(CassiniTheme.warnInk) }
            HStack {
                if test.phase == .result {
                    Button(UXText.text("test.again")) { test.start() }
                    Button(UXText.text("test.playBack")) { test.play() }.disabled(test.heard.isEmpty || test.playing)
                }
                Spacer()
                Button(UXText.text("common.done")) { test.cancel() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width:460)
            .accessibilityIdentifier("test-recording-sheet")
            .onAppear { test.start() }.onDisappear { test.cancel() }
    }
}
