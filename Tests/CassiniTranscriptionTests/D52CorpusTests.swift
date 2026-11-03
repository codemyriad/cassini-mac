// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniKit
import CassiniLibrary
@testable import CassiniTranscription

/// D52 shared production-shaped corpus (conformance/multistream, protocol 3238aab;
/// was c6f5fc7), materialized by its deterministic stdlib generator and hash-checked
/// against a pinned digest (D52.3e), then read through the Mac scanner, speaker
/// lanes and others-ownership placement.
final class D52CorpusTests: XCTestCase {
    /// SHA-256 of the sorted "./relative/path <sha256>\n" listing of every generated file.
    static let pinnedDigest = "b27a8422a8295d58f64f99e4ef188d2802fdb35f4008c0f0215c5daaa2f3b5b0"
    static func materialize() throws -> URL {
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D52Corpus-"+UUID().uuidString)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
        process.arguments = ["python3","-I",repository.appendingPathComponent("browser-protocol/conformance/multistream/make.py").path,root.path]
        process.standardOutput = Pipe(); try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        return root
    }
    private func digest(_ root: URL) throws -> String {
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath:root.path)).compactMap { $0 as? String }
            .filter { (try? root.appendingPathComponent($0).resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var listing = ""
        for file in files {
            let hash = SHA256.hash(data:try Data(contentsOf:root.appendingPathComponent(file))).map { String(format:"%02x",$0) }.joined()
            listing += "./\(file) \(hash)\n"
        }
        return SHA256.hash(data:Data(listing.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    func testCorpusIsPinnedAndPlacesEverySourceOnce() throws {
        let root = try sharedCorpus()
        XCTAssertEqual(try digest(root),Self.pinnedDigest,"Generated corpus differs from the pinned expectation")
        let meetings = try LibraryScanner(root:root).scan().meetings
        XCTAssertEqual(meetings.count,2)
        let call = try XCTUnwrap(meetings.first { $0.audioTracks.count == 8 })
        // M1: unequal disjoint spans of one source stay one speaker; nothing is separated.
        let spans = call.audioTracks.compactMap { track -> SourceSpanLanes.Span? in
            let speaker = TranscriptSpeaker.fromTrack(id:track.sourceID ?? "",kind:track.sourceKind ?? "media",sourceTrackID:track.sourceTrackID)
            guard speaker.id.hasPrefix("track-"), let id = track.sourceID else { return nil }
            return .init(id:id,base:speaker.id,startMs:track.startOffsetMs,endMs:track.endOffsetMs)
        }
        let lanes = SourceSpanLanes.assign(spans)
        XCTAssertEqual(Set(lanes.values),["track-source-a","track-source-b"])
        XCTAssertEqual(lanes.values.filter { $0 == "track-source-a" }.count,3)
        // D49/D33: system and browser never own the same instant; each seam is half-open.
        let ownership = try XCTUnwrap(OthersOwnership(events:call.captureEvents))
        let owned = call.audioTracks.map { track in
            (track.sourceKind,ownership.owned(kind:track.sourceKind,startMs:track.startOffsetMs ?? 0,endMs:track.endOffsetMs ?? 0))
        }
        for at in stride(from:0.0,to:90000,by:250) {
            let roles = Set(owned.filter { $0.1.contains { at >= $0.0 && at < $0.1 } }.compactMap { OthersOwnership.role(kind:$0.0) })
            XCTAssertFalse(roles.contains("system") && roles.contains("browser"),"Both own \(at) ms")
        }
        let system = owned.filter { $0.0 == "system" }.flatMap(\.1).map { [$0.0,$0.1] }
        XCTAssertEqual(system,[[0,20000],[50000,60000]])
        let microphone = try XCTUnwrap(owned.first { $0.0 == "microphone" })
        XCTAssertEqual(microphone.1.map { [$0.0,$0.1] },[[0,90000]],"The microphone is never masked")
        // The concurrent call's folder is independent and unmasked.
        let other = try XCTUnwrap(meetings.first { $0.audioTracks.count == 1 })
        XCTAssertEqual(other.audioTracks.first?.sourceTrackID,"other-call-source")
    }

    // MARK: M17 (P15 corpus): Mac's own readers and recognition planning on the corpus

    private struct Spec: Decodable {
        struct Session: Decodable { let id: String; let tracks: [Track] }
        struct Track: Decodable {
            struct Bleed: Decodable { let db: Double; let windows: [[Double]] }
            let id: String; let startMs: Double; let endMs: Double
            let speechWindows: [[Double]]; let presenceWindows: [[Double]]?; let bleed: Bleed?
        }
        let sessions: [Session]
    }
    private func spec() throws -> Spec {
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Spec.self,from:Data(contentsOf:repository.appendingPathComponent("browser-protocol/conformance/multistream/corpus.json")))
    }
    /// Materialized once per class run and only read; generation and decoding dominate the time.
    nonisolated(unsafe) private static var shared: URL?
    nonisolated(unsafe) private static var meters: [String:(Int,RecognitionFallback.ActivityMeter)] = [:]
    override class func tearDown() { if let shared { try? FileManager.default.removeItem(at:shared) }; shared = nil; meters = [:]; super.tearDown() }
    private func sharedCorpus() throws -> URL {
        if let root = Self.shared { return root }
        let root = try Self.materialize(); Self.shared = root; return root
    }
    private func call(_ root: URL) throws -> LibraryMeeting {
        try XCTUnwrap(try LibraryScanner(root:root).scan().meetings.first { $0.audioTracks.count == 8 })
    }
    private static func ms(_ windows: [(Double,Double)]?) -> [[Double]] { (windows ?? []).map { [$0.0,$0.1] } }
    private static func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(max(1,samples.count))).squareRoot()
    }

    /// One track as the transcriber plans it: recognized windows and per-frame activity.
    private struct Planned { let id: String; let kind: String; let offset: Double; let windows: [[Double]]; let active: [Bool] }
    private enum Mutation { case none, gapsIgnored, absoluteGate }
    private func plan(_ meeting: LibraryMeeting, _ mutation: Mutation = .none) throws -> [Planned] {
        let ownership = OthersOwnership(events:meeting.captureEvents)
        return try meeting.audioTracks.map { track in
            let offset = try XCTUnwrap(track.startOffsetMs), kind = track.sourceKind ?? "media"
            func owned(_ gaps: [TrackPresence.Gap]?, _ count: Int) -> [(Double,Double)] {
                MeetingTranscriber.ownedWindows(offsetMs:offset,sampleCount:count,kind:kind,gaps:gaps,ownership:ownership) ?? [(offset,offset + Double(count)/16)]
            }
            // Decoding and metering dominate the time, so each track is metered once, on
            // its real kept ranges. Gap time is stored as zeros, which meter as silence
            // either way, so the presence mutant is judged on its recognized windows.
            let id = track.sourceID ?? ""
            if Self.meters[id] == nil {
                let audio = try SegmentedAudio(url:track.url)
                let kept = MeetingTranscriber.keptRanges(owned(MeetingTranscriber.presenceGaps(track),audio.sampleCount),offsetMs:offset,sampleCount:audio.sampleCount)
                Self.meters[id] = (audio.sampleCount,try MeetingTranscriber.activity(audio,kept:kept))
            }
            let (count,meter) = try XCTUnwrap(Self.meters[id])
            let windows = owned(mutation == .gapsIgnored ? nil : MeetingTranscriber.presenceGaps(track),count)
            // The mutant drops the per-track floor and the -50 dBFS minimum: any frame above -70 dBFS is speech.
            let active = mutation == .absoluteGate ? meter.codes.map { $0 != 255 && Int($0) - 120 >= -70 } : meter.active()
            return .init(id:id,kind:kind,offset:offset,windows:Self.ms(windows),active:active)
        }
    }
    /// Every failure of the corpus expectations; empty when Mac matches the corpus.
    private func failures(_ planned: [Planned], _ session: Spec.Session) -> [String] {
        var result: [String] = []
        let frameMs = Double(RecognitionFallback.frame) / 16
        for track in session.tracks {
            guard let mine = planned.first(where: { $0.id == track.id }) else { result.append("\(track.id): not read"); continue }
            // D52.2: recognized time is the presence (extent minus gap ranges) inside ownership.
            let expected = track.presenceWindows ?? [[track.startMs,track.endMs]]
            if mine.windows != expected { result.append("\(track.id): recognizes \(mine.windows), expected \(expected)") }
            // R71 activity: only where the corpus put speech (never bleed, gaps or zero fill),
            // and a real share of each speech window (the clips start and pause inside them).
            let frames = mine.active.indices.filter { mine.active[$0] }.map { mine.offset + (Double($0) + 0.5) * frameMs }
            let stray = frames.filter { at in !track.speechWindows.contains { at >= $0[0] - 100 && at < $0[1] + 100 } }
            if !stray.isEmpty { result.append("\(track.id): \(stray.count) active frames outside speech, first at \(Int(stray[0])) ms") }
            for window in track.speechWindows {
                let inside = frames.filter { $0 >= window[0] && $0 < window[1] }.count
                let share = Double(inside) * frameMs / (window[1] - window[0])
                if share < 0.25 { result.append("\(track.id): only \(Int(share*100))% of speech \(window) is active") }
            }
        }
        // D49/D33: system and browser never both recognized at one instant.
        let system = planned.filter { OthersOwnership.role(kind:$0.kind) == "system" }.flatMap(\.windows)
        let browser = planned.filter { OthersOwnership.role(kind:$0.kind) == "browser" }.flatMap(\.windows)
        for s in system { for b in browser where max(s[0],b[0]) < min(s[1],b[1]) { result.append("system \(s) and browser \(b) overlap") } }
        return result
    }

    /// P15 shape guard, read through Mac's scanner: the corpus still holds every
    /// production shape the shared tests rely on.
    func testCorpusShapeGuard() throws {
        let root = try sharedCorpus()
        let meetings = try LibraryScanner(root:root).scan().meetings
        XCTAssertEqual(meetings.count,2,"two concurrent folders")
        let meeting = try call(root)
        let remotes = meeting.audioTracks.filter { OthersOwnership.role(kind:$0.sourceKind) == "browser" }
        XCTAssertTrue(remotes.contains { late in (late.startOffsetMs ?? 0) >= 30000 && !remotes.contains { $0.sourceTrackID == late.sourceTrackID && ($0.startOffsetMs ?? 0) < 30000 } },
                      "a remote that starts at least 30 s late")
        XCTAssertTrue(remotes.contains { track in
            guard let start = track.startOffsetMs, let end = track.endOffsetMs, let frames = track.frameCount, let rate = track.sampleRate else { return false }
            let present = TrackPresence.windows(startOffsetMs:start,sampleRate:rate,frames:frames,gaps:track.gaps).present
            return present.reduce(0) { $0 + $1.end - $1.start } < 0.5 * (end - start)
        },"a span under 50% presence")
        let bySource = Dictionary(grouping:remotes.filter { $0.sourceTrackID != nil },by:{ $0.sourceTrackID! })
        XCTAssertTrue(bySource.values.contains { spans in
            let lengths = spans.compactMap { t in t.endOffsetMs.flatMap { e in t.startOffsetMs.map { e - $0 } } }
            return spans.count >= 2 && (lengths.max() ?? 0) >= 5 * (lengths.min() ?? .infinity)
        },"two or more spans of one source, lengths differing at least 5x")
        let sources = meeting.captureEvents.filter { $0.type == "othersSource" }.map { "\($0.source ?? "")/\($0.reason ?? "")" }
        XCTAssertTrue(sources.contains("browser/callConnected"),"a D49 switch")
        XCTAssertTrue(sources.joined(separator:" ").contains("system/lost browser/restored"),"browser to system to browser")
        XCTAssertTrue(meeting.audioTracks.contains { $0.gaps?.contains { $0.kind == "jump" && $0.frames != nil } == true },"a gap with its range")
        // -35 dB bleed, measured on the stored PCM: the mic's bleed-only time against the source it leaks from.
        let bleed = try XCTUnwrap(spec().sessions[0].tracks.first { $0.bleed != nil }?.bleed)
        let window = bleed.windows[0]
        let mic = try SegmentedAudio(url:XCTUnwrap(meeting.audioTracks.first { $0.sourceKind == "microphone" }?.url))
        let b = try SegmentedAudio(url:XCTUnwrap(meeting.audioTracks.first { $0.sourceID == "b" }?.url))
        let micLevel = Self.rms(try mic.samples(.init(startSample:Int(window[0]*16),endSample:Int(window[1]*16),reason:"bleed"))[...])
        let bLevel = Self.rms(try b.samples(.init(startSample:0,endSample:Int((window[1]-window[0])*16),reason:"bleed"))[...])
        XCTAssertEqual(20*log10(micLevel/bLevel),bleed.db,accuracy:1,"-35 dB bleed")
    }

    /// M17: recognition placement and R71 activity on the corpus, through the
    /// transcriber's own presence, ownership and activity code.
    func testRecognitionPlanMatchesTheCorpus() throws {
        let root = try sharedCorpus()
        let session = try spec().sessions[0], planned = try plan(call(root))
        XCTAssertEqual(failures(planned,session),[])
        // Overlapping speech stays active on both people.
        for id in ["mic","b-return"] {
            let track = try XCTUnwrap(planned.first { $0.id == id })
            let first = Int((60000 - track.offset) / 32), last = Int((68000 - track.offset) / 32)
            XCTAssertGreaterThan(track.active[first..<last].filter { $0 }.count,(last-first)/2,"\(id) speaks during the overlap")
        }
    }

    /// The corpus checks must fail on the mutations gocassini aefb64f1 guards against.
    func testCorpusChecksCatchPresenceAndFloorMutations() throws {
        let root = try sharedCorpus()
        let session = try spec().sessions[0], meeting = try call(root)
        let ignored = failures(try plan(meeting,.gapsIgnored),session)
        XCTAssertTrue(ignored.contains { $0.hasPrefix("a-long: recognizes") },"\(ignored)")
        XCTAssertTrue(ignored.contains { $0.hasPrefix("b-return: recognizes") },"\(ignored)")
        let gate = failures(try plan(meeting,.absoluteGate),session)
        XCTAssertTrue(gate.contains { $0.hasPrefix("mic:") && $0.contains("outside speech") },"\(gate)")
    }
}
