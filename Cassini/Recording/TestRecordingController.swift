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
    private(set) var levels: [CaptureSide: Float] = [:]
    private(set) var refused: [CaptureSide:String] = [:]
    private(set) var playing = false
    private var startedAt: Date?
    private var cleaning = 0
    var hasPendingWork: Bool { phase != .idle || cleaning > 0 || task != nil }
    var canStart: Bool { !RecordingOverview.active && !RecordingOverview.starting && !RecordingOverview.saving && phase == .idle }
    @ObservationIgnored private var nativeDrivers: [TestRecordingInput] = []
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
    @ObservationIgnored var makeMicrophone: @MainActor () -> any CaptureInput = { TestRecordingInput(.me) }
    @ObservationIgnored var makeSystem: @MainActor () -> any CaptureInput = { TestRecordingInput(.others) }
    @ObservationIgnored var changed: (() -> Void)?
    init() { cleaning = 1; cleanup = Task { await Self.sweep(); cleaning -= 1 } }
    static var root: URL {
        #if DEBUG
        let temporary = SettingsFixture.temporaryDirectory
        #else
        let temporary = FileManager.default.temporaryDirectory
        #endif
        return temporary.appendingPathComponent("Cassini-TestRecording",isDirectory:true)
    }

    #if DEBUG
    var fixtureDirectory: URL? { owner?.snapshot.directory }
    var playAutomatically = true
    private(set) var isFrozen = false
    private var frozenElapsedMs: Int64?
    func freezeForScreenshot(phase: Phase, elapsedMs: Int64 = 3_000, heard: Set<CaptureSide>, levels: [CaptureSide: Float]) {
        isFrozen = true; frozenElapsedMs = elapsedMs
        self.phase = phase; self.heard = heard; self.levels = levels
        self.refused = [:]; self.problem = nil; self.playing = false
        self.presented = true
    }
    #else
    var isFrozen: Bool { false }
    #endif
    func elapsedMs(at date: Date) -> Int64 {
        #if DEBUG
        if let frozenElapsedMs { return frozenElapsedMs }
        #endif
        guard let startedAt else { return 0 }
        return max(0, Int64(date.timeIntervalSince(startedAt) * 1000))
    }
    func start() {
        #if DEBUG
        isFrozen = false; frozenElapsedMs = nil
        #endif
        guard canStart || phase == .result else { return }
        let previous = cancel(close:false)
        let attempt = UUID(); generation = attempt
        phase = .starting; problem = nil; heard = []; levels = [:]; refused = [:]; startedAt = nil
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
                    microphone:{ [self] in
                        let driver = makeMicrophone()
                        if let native = driver as? TestRecordingInput { nativeDrivers.append(native) }
                        return driver
                    },system:{ [self] in
                        let driver = makeSystem()
                        if let native = driver as? TestRecordingInput { nativeDrivers.append(native) }
                        return driver
                    },failure:{ [weak self] message in
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
                startedAt = Date(); phase = .recording; changed?()
                meter = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sampleLevels() }
                }
                try await duration()
                guard generation == attempt else { return }
                sampleLevels(); meter?.invalidate(); meter = nil
                phase = .finishing
                try await input.stop()
                for driver in nativeDrivers { await driver.drain() }
                do { try await owner.finish() }
                catch {
                    // A disposable test with no PCM reports silent/refused sides.
                    // Preserve real writer failures; only the writer's explicit
                    // empty-recording outcome is expected for this dialog.
                    let ended = owner.snapshot
                    guard ended.phase == .saved, ended.manifest.problemKind == "empty",
                          ended.manifest.tracks.allSatisfy({ $0.frames == 0 }) else { throw error }
                }
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
                let pending = cancel(close:false,waitForRun:false)
                let cancelled = generation
                await pending.value
                guard generation == cancelled else { return }
                phase = .result; changed?()
            }
        }
    }
    private func sampleLevels() {
        guard let input else { return }
        for (side,status) in input.availableStatus() {
            let peak = status?.levels.values.max() ?? 0
            levels[side] = peak
            if peak >= 0.01 { heard.insert(side) }
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
    @discardableResult func cancel(close: Bool = true, waitForRun: Bool = true) -> Task<Void,Never> {
        let running = task
        generation = UUID(); task?.cancel(); task = nil
        meter?.invalidate(); meter = nil; stopPlayer(); timeline = nil
        let input = self.input, owner = self.owner, previous = cleanup, drivers = nativeDrivers
        nativeDrivers = []
        self.input = nil; self.owner = nil; phase = .idle; startedAt = nil; levels = [:]
        if close { presented = false }
        cleaning += 1
        let next = Task {
            await previous?.value
            try? await input?.stop()
            for driver in drivers { await driver.drain() }
            if waitForRun { await running?.value }
            if let owner { await Self.remove(owner) }
            cleaning -= 1
        }
        cleanup = next; changed?(); return next
    }
    private static func remove(_ owner: OwnedBrowserCapture) async {
        await Task.detached(priority:.utility) {
            try? await owner.finish()
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(UXText.text("test.action"))
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if test.phase == .result {
                        Text(UXText.text("test.note"))
                            .foregroundStyle(CassiniTheme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            MeetingStatusBadge(
                                kind: .recording,
                                label: UXText.text("states.badge.recording", ["liveBadge": LibraryFormat.liveBadge(test.elapsedMs(at: context.date))]),
                                isAnimating: !test.isFrozen
                            )
                        }
                    }
                }
                .frame(minHeight: 22, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 14) {
                TestRecordingSourceRow(
                    side: .me,
                    phase: test.phase,
                    heard: test.heard.contains(.me),
                    level: test.levels[.me] ?? 0,
                    refusal: test.refused[.me]
                )
                Divider()
                TestRecordingSourceRow(
                    side: .others,
                    phase: test.phase,
                    heard: test.heard.contains(.others),
                    level: test.levels[.others] ?? 0,
                    refusal: test.refused[.others]
                )
            }
            if let problem = test.problem {
                Text(problem).foregroundStyle(CassiniTheme.warnInk).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(UXText.text("test.playBack")) { test.play() }
                    .disabled(test.phase != .result || test.heard.isEmpty || test.playing)
                    .fixedSize()
                    .accessibilityIdentifier("test-recording-play")
                Spacer(minLength: 12)
                Button(UXText.text("test.again")) { test.start() }
                    .disabled(test.phase != .result)
                    .fixedSize()
                    .accessibilityIdentifier("test-recording-again")
                Button(UXText.text(test.phase == .result ? "common.done" : "common.cancel")) { test.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                    .accessibilityIdentifier(test.phase == .result ? "test-recording-done" : "test-recording-cancel")
            }
            .padding(.top, 4)
        }
        .font(.system(size: 13))
        .padding(28)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(UXText.text("test.action"))
        .accessibilityIdentifier("test-recording-sheet")
        .onAppear { if !test.isFrozen { test.start() } }
        .onDisappear { if !test.isFrozen { test.cancel() } }
    }
}

private struct TestRecordingSourceRow: View {
    let side: CaptureSide
    let phase: TestRecordingController.Phase
    let heard: Bool
    let level: Float
    let refusal: String?

    private var iconName: String { side == .me ? "mic.fill" : "display" }
    private var promptKey: String { side == .me ? "test.mic.prompt" : "test.sound.prompt" }
    private var sourceKey: String { side == .me ? "common.yourMicrophone" : "recordFirst.sound.title" }
    private var liveKey: String {
        if !heard { return "test.live.waiting" }
        return side == .me ? "test.live.hearing" : "test.live.hearingSound"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: iconName)
                    .frame(width: 36, height: 36)
                    .background(CassiniTheme.subtleWash, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(UXText.text(promptKey)).fontWeight(.semibold)
                    Text(UXText.text(sourceKey))
                        .font(.system(size: 11.5))
                        .foregroundStyle(CassiniTheme.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if phase == .result {
                    TestRecordingStatusPill(working: heard)
                } else {
                    HStack(spacing: 8) {
                        TestRecordingLevelMeter(level: level)
                        Text(UXText.text(liveKey))
                            .font(.system(size: 12))
                            .foregroundStyle(heard ? CassiniTheme.ink : CassiniTheme.secondaryInk)
                            .fixedSize()
                    }
                }
            }
            if phase == .result, let refusal {
                let source = UXText.text(sourceKey)
                Text(UXText.text(refusal == CaptureRefusal.permissionDenied ? "details.sources.refused.permissionDenied" : "details.sources.refused.deviceUnavailable", ["source": source]))
                    .font(.system(size: 11.5))
                    .foregroundStyle(CassiniTheme.warnInk)
                    .padding(.leading, 50)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TestRecordingLevelMeter: View {
    let level: Float
    private var normalized: CGFloat {
        let clamped = max(0, min(1, level))
        // Boost low speech amplitudes slightly so live movement is legible at a glance.
        return CGFloat(sqrt(clamped))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(CassiniTheme.neutralPillFill)
            Capsule().fill(CassiniTheme.accent)
                .frame(width: max(0, 48 * normalized))
        }
        .frame(width: 48, height: 6)
        .accessibilityHidden(true)
    }
}

private struct TestRecordingStatusPill: View {
    let working: Bool

    var body: some View {
        HStack(spacing: MeetingStatusBadge.Metrics.gap) {
            Image(systemName: working ? "checkmark" : "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(working ? CassiniTheme.success : CassiniTheme.error)
                .accessibilityHidden(true)
            Text(UXText.text(working ? "test.pill.working" : "test.pill.silent"))
                .font(.system(size: MeetingStatusBadge.Metrics.font, weight: .semibold))
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(working ? CassiniTheme.success : CassiniTheme.error)
        }
        .padding(.horizontal, MeetingStatusBadge.Metrics.horizontalPadding)
        .frame(height: MeetingStatusBadge.Metrics.height)
        .fixedSize(horizontal: true, vertical: true)
        .background(Capsule().fill(working ? CassiniTheme.successTint : CassiniTheme.errorTint))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UXText.text(working ? "test.pill.working" : "test.pill.silent"))
    }
}
