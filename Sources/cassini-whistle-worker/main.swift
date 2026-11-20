// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniWhistle
import CassiniTranscription
import CassiniLibrary
import Foundation
import Darwin

// One model per child process; sequential line requests reuse it. The app's
// transcription queue owns at most one child, never an in-process engine.
struct Request: Decodable {
    let id: String
    let action: String?
    let wav: String?
    let meeting: String?
    let me: String?
    let others: String?
    let uiLanguage: String?
}
struct Response: Encodable {
    let id: String?
    var transcript: WhistleTranscript?
    var error: String?
}
func emit(_ response: Response) throws {
    try WhistleIO.write(JSONEncoder().encode(response) + Data([10]), to: STDOUT_FILENO)
}
final class EngineBox: @unchecked Sendable {
    let engine: WhistleEngine
    init(_ engine: WhistleEngine) { self.engine = engine }
}
final class VADAssetsBox: @unchecked Sendable {
    let assets: VADAssets
    init(_ assets: VADAssets) { self.assets = assets }
}
do {
    // The exact C environment is checked before asset verification or dlopen.
    try WhistleEnvironment.validateLive()
    #if DEBUG
    if try SpeechNetworkProbe.run(arguments: Array(CommandLine.arguments.dropFirst())) { exit(0) }
    #endif
    // A killed parent cannot cancel its Task. Reparenting must stop this helper
    // even while the recognizer is inside a blocking native call. Do not use
    // stdin EOF as liveness: clients close stdin after their final request.
    let owner = getppid()
    guard owner > 1 else { exit(0) }
    let ownerWatchdog = DispatchSource.makeTimerSource(queue: .global())
    ownerWatchdog.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
    // Top-level Swift code is main-actor isolated. Dispatch's preconcurrency
    // callback must explicitly be Sendable or Swift6.1 checks that isolation
    // on the global queue and traps at the first watchdog tick.
    #if DEBUG
    // Private inherited-FD acknowledgement for event-driven owner-lifetime tests.
    // No stdout/protocol message or release-worker behavior changes.
    let ownerTickFD = Int32(ProcessInfo.processInfo.environment["CASSINI_TEST_OWNER_TICK_FD"] ?? "")
    #endif
    ownerWatchdog.setEventHandler { @Sendable in
        if getppid() != owner { exit(0) }
        #if DEBUG
        if let fd = ownerTickFD, fd >= 3 {
            var tick: UInt8 = 1
            _ = write(fd, &tick, 1)
        }
        #endif
    }
    ownerWatchdog.resume()
    defer { ownerWatchdog.cancel() }
    #if DEBUG
    if Array(CommandLine.arguments.dropFirst()) == ["--fixture-wait-for-cancellation"] {
        // The app's private queue fixtures need a real owned child that cannot
        // complete because a host-time sleep elapsed. Keep the owner watchdog
        // running, but load no model and open no audio device.
        DispatchSemaphore(value: 0).wait()
        exit(0)
    }
    #endif
    SegmentedAudio.removeAbandonedScratch()
    let assets = try WhistleAssets.forWorker(arguments: Array(CommandLine.arguments.dropFirst()))
    let engine = try WhistleEngine(assets: assets)
    let engineBox = EngineBox(engine)
    #if DEBUG
    // Private inherited-FD event: initialization finished, before any input or
    // stdout write. Fatal-input tests must retain their first-message coverage.
    if let value = ProcessInfo.processInfo.environment["CASSINI_TEST_ENGINE_READY_FD"],
       let fd = Int32(value), fd >= 3 {
        defer { close(fd) }
        try WhistleIO.write(Data([1]), to: fd)
    }
    #endif
    var vadAssets: VADAssets?
    let follower = SessionFollowerController()
    defer { follower.stop(savePrefixes: false) }
    let lines = WhistleLineReader(fd: STDIN_FILENO)
    while let line = try lines.next() {
        var id: String?
        let response: Response
        var shouldExit = false
        do {
            let request = try JSONDecoder().decode(Request.self, from: line); id = request.id
            let action = request.action
            if action == "shutdown" {
                follower.stop(savePrefixes: false)
                response = Response(id: id)
                shouldExit = true
            } else if action == "stopFollow" {
                follower.stop(savePrefixes: true)
                response = Response(id: id)
            } else if action == "follow" {
                guard let meeting = request.meeting, request.wav == nil else { throw TranscriptionFailure.invalidMeeting }
                let vad = try vadAssets ?? VADAssets.verified(for: assets)
                vadAssets = vad
                let vadBox = VADAssetsBox(vad)
                try follower.start(
                    directory: URL(fileURLWithPath: meeting),
                    modelIdentity: WhistleAssets.modelIdentity,
                    makeDetector: { try SpeechDetector(assets: vadBox.assets) },
                    recognize: { try engineBox.engine.transcribe(samples: $0) }
                )
                response = Response(id: id)
            } else if (action == nil || action == "transcribeMeeting"), let meeting = request.meeting, request.wav == nil {
                let meetingURL = URL(fileURLWithPath: meeting)
                let prefixes = follower.takePrefixes(for: meetingURL)
                let vad = try vadAssets ?? VADAssets.verified(for: assets)
                vadAssets = vad
                let detector = try SpeechDetector(assets: vad)
                try MeetingTranscriber.run(
                    directory: meetingURL,
                    engine: engine,
                    detector: detector,
                    me: request.me ?? "Me",
                    others: request.others ?? "The others",
                    uiLanguage: request.uiLanguage.flatMap(CassiniLanguage.init(rawValue:)) ?? .system,
                    precomputedPrefixes: prefixes
                )
                response = Response(id: id)
            } else if action == nil, let wav = request.wav, request.meeting == nil {
                follower.stop(savePrefixes: false)
                response = Response(id: id, transcript: try engine.transcribe(wav: URL(fileURLWithPath: wav)))
            } else {
                throw TranscriptionFailure.invalidMeeting
            }
        } catch {
            response = Response(id: id, error: String(describing: error))
        }
        try emit(response)
        if shouldExit { break }
    }
} catch {
    try? emit(Response(id: nil, error: String(describing: error)))
    exit(78)
}
