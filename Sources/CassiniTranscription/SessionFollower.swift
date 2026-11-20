// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniRecording
import CassiniWhistle

/// Read-only, capture-isolated incremental session follower for `transcribeWhileRecording` (D-1117 / D-1122).
///
/// Opens `session.json` and `track-*.wav` strictly read-only (`O_RDONLY | O_NOFOLLOW`),
/// carries `MeetingResampler`, `SileroInputHighPass`, `SpeechDetector`, and `SpeechGate` state
/// per track across incremental reads without re-decoding prefixes, schedules ready blocks fairly
/// across simultaneous tracks in earliest-session-time order, and writes closed segment results
/// atomically to `.recognition-cache.json` without ever acquiring `.transcription.lock`.
public final class SessionFollower {
    public struct Stats: Equatable, Sendable {
        public var tracksFollowed: Int = 0
        public var blocksDecoded: Int = 0
        public var segmentsClosed: Int = 0
        public var segmentsRecognized: Int = 0
        public var cacheHits: Int = 0
    }

    private final class TrackState {
        let id: String
        let url: URL
        let canonicalPath: String
        let order: Int
        let header: MeetingAudioDecoder.CanonicalWAVHeader
        var startOffsetMs: Double?
        var consumedFrames: Int = 0
        var prefixHasher = SHA256()
        var resampler: MeetingResampler
        let detector: any SpeechProbabilityProvider
        var gate = SpeechGate()
        let scratch: SpeechScratch
        let stream: FileHandle
        var sampleCount: Int = 0
        var segments: [SpeechSegment] = []
        var transferred = false

        var haloFrames: Int { header.sampleRate == 48000 ? 48 : 0 }
        var nextSessionTimeMs: Double {
            (startOffsetMs ?? 0.0) + Double(consumedFrames) * 1000.0 / Double(header.sampleRate)
        }

        init(
            id: String,
            url: URL,
            canonicalPath: String,
            order: Int,
            header: MeetingAudioDecoder.CanonicalWAVHeader,
            startOffsetMs: Double?,
            detector: any SpeechProbabilityProvider
        ) throws {
            self.id = id
            self.url = url
            self.canonicalPath = canonicalPath
            self.order = order
            self.header = header
            self.startOffsetMs = startOffsetMs
            self.resampler = try MeetingResampler(rate: header.sampleRate)
            self.detector = detector
            self.detector.reset()
            self.scratch = try SpeechScratch()
            let mono = scratch.directory.appendingPathComponent("mono.f32")
            guard FileManager.default.createFile(atPath: mono.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw TranscriptionFailure.audioFormat
            }
            self.stream = try FileHandle(forUpdating: mono)
        }

        deinit {
            if !transferred { try? stream.close() }
        }

        func readSegmentSamples(_ segment: SpeechSegment) throws -> [Float] {
            let count = segment.endSample - segment.startSample
            guard count > 0 && count <= 240512 else { throw TranscriptionFailure.audioFormat }
            try stream.seek(toOffset: UInt64(segment.startSample * 4))
            let data = try stream.read(upToCount: count * 4) ?? Data()
            guard data.count == count * 4 else { throw TranscriptionFailure.audioFormat }
            return data.withUnsafeBytes { bytes in
                (0..<count).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
        }
    }

    public let directory: URL
    public let modelIdentity: String
    private let makeDetector: () throws -> any SpeechProbabilityProvider
    private let recognize: ([Float]) throws -> WhistleTranscript
    private let maxBlockFrames: Int

    private let condition = NSCondition()
    private var cancelled = false

    private var tracks: [String: TrackState] = [:]
    private var cache: SegmentRecognitionCache.Store
    public private(set) var stats = Stats()

    public init(
        directory inputDirectory: URL,
        modelIdentity: String,
        maxBlockFrames: Int = 8192,
        makeDetector: @escaping () throws -> any SpeechProbabilityProvider,
        recognize: @escaping ([Float]) throws -> WhistleTranscript
    ) throws {
        var info = stat()
        guard lstat(inputDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let canonical = realpath(inputDirectory.path, nil) else {
            throw TranscriptionFailure.invalidMeeting
        }
        self.directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        self.modelIdentity = modelIdentity
        self.maxBlockFrames = max(512, maxBlockFrames)
        self.makeDetector = makeDetector
        self.recognize = recognize
        self.cache = SegmentRecognitionCache.Store.load(directory: self.directory, modelIdentity: modelIdentity)
    }

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Runs the follower loop until `cancel()` is called. Wakes immediately on cancellation.
    public func runLoop(pollIntervalMs: Int = 100) {
        let interval = max(10, pollIntervalMs)
        while !isCancelled {
            let didWork: Bool
            do {
                didWork = try step()
            } catch {
                // Capture isolation: any transient/non-fatal read error never disturbs capture.
                // Stop if cancelled; otherwise retry on next poll tick.
                if isCancelled { break }
                didWork = false
            }
            if !didWork {
                condition.lock()
                if !cancelled {
                    _ = condition.wait(until: Date().addingTimeInterval(Double(interval) / 1000.0))
                }
                condition.unlock()
            }
        }
    }

    /// Performs one fair-scheduled block step across active tracks.
    /// Returns `true` if a block was processed, `false` if all tracks are at their safe halo frontier.
    @discardableResult
    public func step() throws -> Bool {
        if isCancelled { return false }
        refreshManifest()
        if isCancelled { return false }

        // Find all tracks with committed physical frames beyond the FIR right-halo margin.
        var ready: [(state: TrackState, readableFrames: Int)] = []
        for state in tracks.values {
            guard let physicalFrames = physicalFrameCount(url: state.url, header: state.header) else { continue }
            let readable = max(0, physicalFrames - state.haloFrames)
            if readable > state.consumedFrames {
                ready.append((state, readable))
            }
        }
        guard !ready.isEmpty else { return false }

        // Fair scheduling: pick the ready track with the earliest session time (tie-break by manifest order).
        ready.sort { a, b in
            if a.state.nextSessionTimeMs != b.state.nextSessionTimeMs {
                return a.state.nextSessionTimeMs < b.state.nextSessionTimeMs
            }
            return a.state.order < b.state.order
        }
        let chosen = ready[0]
        let state = chosen.state
        let framesToRead = min(chosen.readableFrames - state.consumedFrames, maxBlockFrames)
        guard framesToRead > 0 else { return false }

        guard let rawBlock = readCommittedPCMBytes(
            url: state.url,
            header: state.header,
            fromFrame: state.consumedFrames,
            frameCount: framesToRead
        ) else { return false }

        let actualFrames = rawBlock.count / state.header.stride
        guard actualFrames > 0 else { return false }
        let exactBytes = actualFrames * state.header.stride
        let alignedBlock = rawBlock.count == exactBytes ? rawBlock : rawBlock.prefix(exactBytes)

        state.prefixHasher.update(data: alignedBlock)
        let mono = MeetingAudioDecoder.pcm16ToMonoFloat(Data(alignedBlock), channels: state.header.channels)
        let resampled = state.resampler.feed(mono, final: false)

        if !resampled.isEmpty {
            try state.stream.seekToEnd()
            try resampled.withUnsafeBytes { try state.stream.write(contentsOf: $0) }
            state.sampleCount += resampled.count
            let newlyClosed = try state.gate.feed(resampled, probability: state.detector.probability)
            state.segments.append(contentsOf: newlyClosed)
            stats.segmentsClosed += newlyClosed.count

            for segment in newlyClosed {
                if isCancelled { break }
                let samples = try state.readSegmentSamples(segment)
                if cache.lookup(samples: samples) != nil {
                    stats.cacheHits += 1
                    continue
                }
                let transcript = try recognize(samples)
                stats.segmentsRecognized += 1
                if let key = SegmentRecognitionCache.deriveKey(modelIdentity: modelIdentity, samples: samples),
                   let entry = SegmentRecognitionCache.entry(from: transcript, sampleCount: samples.count) {
                    cache.insert(key: key, entry: entry)
                    // Atomic write without `.transcription.lock`; failure is non-fatal for capture.
                    try? cache.saveAtomically(to: directory)
                }
            }
        }

        state.consumedFrames += actualFrames
        stats.blocksDecoded += 1
        return true
    }

    /// Transfers verified incremental track states to `MeetingTranscriber.run` for warm post-Stop handoff.
    /// Must be called after `runLoop()` has exited (after `cancel()`).
    public func takeVerifiedPrefixes() -> [String: PrecomputedTrackPrefix] {
        var result: [String: PrecomputedTrackPrefix] = [:]
        for (path, state) in tracks {
            guard !state.transferred, state.consumedFrames > 0 else { continue }
            state.transferred = true
            let digest = state.prefixHasher.finalize().map { String(format: "%02x", $0) }.joined()
            result[path] = PrecomputedTrackPrefix(
                url: state.url,
                header: state.header,
                consumedFrames: state.consumedFrames,
                wavPrefixSha256: digest,
                sampleCount: state.sampleCount,
                segments: state.segments,
                resampler: state.resampler,
                detector: state.detector,
                gate: state.gate,
                scratch: state.scratch,
                stream: state.stream
            )
        }
        tracks.removeAll()
        return result
    }

    private func refreshManifest() {
        let sessionURL = directory.appendingPathComponent("session.json")
        guard let data = try? WhistleIO.readRegular(sessionURL, maximum: 16 * 1024 * 1024),
              let manifest = try? RecordingLoader.decode(data) else {
            return
        }
        let dirPrefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        for (order, track) in manifest.tracks.enumerated() {
            guard track.file == URL(fileURLWithPath: track.file).lastPathComponent,
                  !track.file.contains("/"), track.file != ".", track.file != "..",
                  track.file.lowercased().hasSuffix(".wav"),
                  [16000, 48000].contains(track.sampleRate),
                  [1, 2].contains(track.channels) else { continue }
            let url = directory.appendingPathComponent(track.file)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            guard let canonicalPtr = realpath(url.path, nil) else { continue }
            let canonicalPath = String(cString: canonicalPtr)
            free(canonicalPtr)
            guard canonicalPath.hasPrefix(dirPrefix) else { continue }

            if let existing = tracks[canonicalPath] {
                if existing.startOffsetMs == nil, let offset = track.startOffsetMs {
                    existing.startOffsetMs = offset
                }
                continue
            }

            guard let header = readCanonicalWAVHeader(url: url),
                  header.sampleRate == track.sampleRate,
                  header.channels == track.channels else { continue }
            guard let detector = try? makeDetector(),
                  let state = try? TrackState(
                    id: track.id,
                    url: url,
                    canonicalPath: canonicalPath,
                    order: order,
                    header: header,
                    startOffsetMs: track.startOffsetMs,
                    detector: detector
                  ) else { continue }
            tracks[canonicalPath] = state
            stats.tracksFollowed = tracks.count
        }
    }

    private func readCanonicalWAVHeader(url: URL) -> MeetingAudioDecoder.CanonicalWAVHeader? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 44 else {
            close(fd); return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 44) else { return nil }
        return MeetingAudioDecoder.parseCanonicalWAVHeader(data)
    }

    private func physicalFrameCount(url: URL, header: MeetingAudioDecoder.CanonicalWAVHeader) -> Int? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 44 else { return nil }
        return Int((UInt64(info.st_size) - 44) / UInt64(header.stride))
    }

    private func readCommittedPCMBytes(
        url: URL,
        header: MeetingAudioDecoder.CanonicalWAVHeader,
        fromFrame: Int,
        frameCount: Int
    ) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd); return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let byteOffset = UInt64(44) + UInt64(fromFrame) * UInt64(header.stride)
        let byteCount = frameCount * header.stride
        guard UInt64(info.st_size) >= byteOffset + UInt64(byteCount) else { return nil }
        do {
            try handle.seek(toOffset: byteOffset)
            return try handle.read(upToCount: byteCount)
        } catch {
            return nil
        }
    }
}

/// Manages one background utility-QoS `SessionFollower` thread and hands off verified track prefixes
/// to `MeetingTranscriber.run` inside a warm worker process (`cassini-whistle-worker` / `cassini-parakeet-worker`).
public final class SessionFollowerController: @unchecked Sendable {
    private final class RunnerBox: @unchecked Sendable {
        let follower: SessionFollower
        let done = DispatchSemaphore(value: 0)
        init(_ follower: SessionFollower) { self.follower = follower }
    }

    private var active: (meetingPath: String, box: RunnerBox)?
    private var savedPrefixes: (meetingPath: String, prefixes: [String: PrecomputedTrackPrefix])?

    public init() {}

    public func start(
        directory: URL,
        modelIdentity: String,
        makeDetector: @escaping @Sendable () throws -> any SpeechProbabilityProvider,
        recognize: @escaping @Sendable ([Float]) throws -> WhistleTranscript
    ) throws {
        stop(savePrefixes: false)
        savedPrefixes = nil
        let follower = try SessionFollower(
            directory: directory,
            modelIdentity: modelIdentity,
            makeDetector: makeDetector,
            recognize: recognize
        )
        let box = RunnerBox(follower)
        let thread = Thread {
            box.follower.runLoop(pollIntervalMs: 100)
            box.done.signal()
        }
        thread.qualityOfService = .utility
        thread.name = "cassini.session-follower"
        active = (follower.directory.path, box)
        thread.start()
    }

    public func stop(savePrefixes: Bool) {
        guard let current = active else { return }
        active = nil
        current.box.follower.cancel()
        current.box.done.wait()
        if savePrefixes {
            let prefixes = current.box.follower.takeVerifiedPrefixes()
            savedPrefixes = prefixes.isEmpty ? nil : (current.meetingPath, prefixes)
        } else {
            _ = current.box.follower.takeVerifiedPrefixes()
            savedPrefixes = nil
        }
    }

    /// Stops any active follower and returns verified prefixes iff they belong to `directory`.
    public func takePrefixes(for directory: URL) -> [String: PrecomputedTrackPrefix] {
        stop(savePrefixes: true)
        defer { savedPrefixes = nil }
        guard let saved = savedPrefixes else { return [:] }
        let canonical = realpath(directory.path, nil).map { ptr -> String in
            defer { free(ptr) }
            return String(cString: ptr)
        } ?? directory.standardizedFileURL.path
        return saved.meetingPath == canonical ? saved.prefixes : [:]
    }

    deinit {
        stop(savePrefixes: false)
    }
}
