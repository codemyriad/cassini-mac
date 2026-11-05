// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CryptoKit
import CassiniKit
import CassiniLibrary
@testable import CassiniTranscription

/// D52 shared production-shaped corpus (conformance/multistream, corpus v2 at protocol e68ebca;
/// was 3238aab), materialized by its deterministic stdlib generator and hash-checked
/// against a pinned digest (D52.3e), then read through the Mac scanner, speaker
/// lanes and others-ownership placement.
final class D52CorpusTests: XCTestCase {
    /// SHA-256 of the sorted "./relative/path <sha256>\n" listing of every generated file.
    static let pinnedDigest = "c4e8fbcd1c2682ecef3b7350b74ab47e03d319fe8908abf65dd0dd288007e66d"
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
        XCTAssertEqual(meetings.count,3)
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
            struct Bleed: Decodable { let from: String; let db: Double; let windows: [[Double]] }
            let id: String; let startMs: Double; let endMs: Double
            let speechWindows: [[Double]]; let bleeds: [Bleed]?
        }
        /// Corpus v2 expectations (D52.2 presence, R71 activity, D63).
        struct Expected: Decodable {
            struct Track: Decodable {
                let ownership: [[Double]]; let presence16k: [[Int]]; let gaps: [[Double]]; let noWords: [[Double]]
                let floorDb: [Double]; let activeSeconds: [Double]; let fallbackWindowsMs: [[Double]]
            }
            struct TurnCase: Decodable { let speaker: String; let words: [[Int64]]; let turns: [Int] }
            struct Midpoint: Decodable { let track: String; let ms: [Int64]; let keep: Bool }
            struct Session: Decodable {
                let tracks: [String:Track]; let personActiveSeconds: [String:[Double]]; let fallback: [String:Bool]
                let turnBreaksMs: [String:[[Double]]]; let turnCases: [TurnCase]; let wordMidpoints: [Midpoint]
            }
            let sessions: [String:Session]
        }
        let sessions: [Session]
        let expected: Expected
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
    private struct Planned {
        let id: String; let kind: String; let offset: Double; let windows: [[Double]]; let active: [Bool]
        var startSample = 0; var kept: [Range<Int>] = []; var floor: Double? = nil; var ownership: [[Double]] = []; var gaps: [[Double]] = []
    }
    private enum Mutation { case none, gapsIgnored, absoluteGate }
    private func plan(_ meeting: LibraryMeeting, _ mutation: Mutation = .none) throws -> [Planned] {
        let ownership = OthersOwnership(events:meeting.captureEvents)
        return try meeting.audioTracks.map { track in
            // The transcriber's one placement (D55): presence and ownership edges are measured from it.
            let startSample = Int(TrackPlacement.frame(ms:try XCTUnwrap(track.startOffsetMs),rate:16000))
            let offset = Double(startSample) / 16, kind = track.sourceKind ?? "media"
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
            let kept = MeetingTranscriber.keptRanges(owned(MeetingTranscriber.presenceGaps(track),count),offsetMs:offset,sampleCount:count)
            let end = offset + Double(count) / 16
            let owns = ownership.map { $0.owned(kind:kind,startMs:offset,endMs:end).map { [$0.0,$0.1] } } ?? [[offset,end]]
            let rate = Double(track.sampleRate ?? 48000)
            let gaps = (track.gaps ?? []).compactMap { gap -> [Double]? in
                guard gap.kind != "overflow" else { return nil }
                let length = gap.frames.map { Double($0)*1000/rate } ?? gap.durationMs ?? 0
                return length > 0 ? [gap.atMs,gap.atMs + length] : nil
            }
            return .init(id:id,kind:kind,offset:offset,windows:Self.ms(windows),active:active,startSample:startSample,kept:kept,
                         floor:meter.floorDB(),ownership:owns,gaps:gaps)
        }
    }
    /// Every failure of the corpus expectations; empty when Mac matches the corpus.
    private func failures(_ planned: [Planned], _ session: Spec.Session, _ expected: Spec.Expected.Session) -> [String] {
        var result: [String] = []
        let frameMs = Double(RecognitionFallback.frame) / 16
        for track in session.tracks {
            guard let mine = planned.first(where: { $0.id == track.id }) else { result.append("\(track.id): not read"); continue }
            // D52.2: recognized time is the presence (extent minus gap ranges) inside ownership.
            let presence = (expected.tracks[track.id]?.presence16k ?? []).map { [Double($0[0]) / 16,Double($0[1]) / 16] }
            if mine.windows != presence { result.append("\(track.id): recognizes \(mine.windows), expected \(presence)") }
            // R71 activity: only where the corpus put speech (never bleed, gaps or zero fill),
            // and a real share of each speech window (the clips start and pause inside them).
            let frames = mine.active.indices.filter { mine.active[$0] }.map { mine.offset + (Double($0) + 0.5) * frameMs }
            let stray = frames.filter { at in !track.speechWindows.contains { at >= $0[0] - 100 && at < $0[1] + 100 } }
            if !stray.isEmpty { result.append("\(track.id): \(stray.count) active frames outside speech, first at \(Int(stray[0])) ms") }
            // v2 speech windows are [start, end, clip offset] and may run past ownership (D49
            // overlap): the share counts only the part this track is recognized for.
            for window in track.speechWindows {
                let parts = mine.windows.map { (max($0[0],window[0]),min($0[1],window[1])) }.filter { $0.1 > $0.0 }
                let length = parts.reduce(0.0) { $0 + $1.1 - $1.0 }
                guard length > 0 else { continue }
                let inside = frames.filter { at in parts.contains { at >= $0.0 && at < $0.1 } }.count
                let share = Double(inside) * frameMs / length
                if share < 0.25 { result.append("\(track.id): only \(Int(share*100))% of speech \(window[0..<2]) is active") }
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
        XCTAssertEqual(meetings.count,3,"two concurrent folders and the D63 rejoin session")
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
        let bleed = try XCTUnwrap(spec().sessions[0].tracks.first { $0.id == "mic" }?.bleeds?.first { $0.from == "b" })
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
        let spec = try spec(), session = spec.sessions[0], planned = try plan(call(root))
        XCTAssertEqual(failures(planned,session,try XCTUnwrap(spec.expected.sessions[session.id])),[])
        // Overlapping speech stays active on both people (a real share of it, as for any speech
        // window: v2 lays a noise bed under b-return, so its floor and threshold are higher).
        for id in ["mic","b-return"] {
            let track = try XCTUnwrap(planned.first { $0.id == id })
            let first = Int((60000 - track.offset) / 32), last = Int((68000 - track.offset) / 32)
            XCTAssertGreaterThan(track.active[first..<last].filter { $0 }.count,(last-first)/4,"\(id) speaks during the overlap")
        }
    }

    /// Corpus v2 (D52.2, R71, D63) on all three sessions, through the transcriber's own
    /// placement, presence, ownership, activity, windows and write rule, and the Library's
    /// speaker gap ranges and groupers.
    func testCorpusV2ExpectationsThroughMacCode() throws {
        let root = try sharedCorpus(), spec = try spec()
        let meetings = try LibraryScanner(root:root).scan().meetings
        XCTAssertEqual(Set(meetings.map { $0.id.uuidString.lowercased() }),Set(spec.expected.sessions.keys))
        func speaker(_ person: String) -> String { ["me","others"].contains(person) ? person : "track-" + person }
        for meeting in meetings {
            let key = meeting.id.uuidString.lowercased(), expected = try XCTUnwrap(spec.expected.sessions[key])
            let planned = try plan(meeting)
            let speakers = Dictionary(TranscriptSpeaker.assign(meeting.audioTracks,received:false).map { (TranscriptSpeaker.trackID($0.track),$0.speaker.id) },uniquingKeysWith:{ a,_ in a })
            for (id,want) in expected.tracks {
                let mine = try XCTUnwrap(planned.first { $0.id == id },"\(key) \(id)")
                XCTAssertEqual(mine.ownership,want.ownership,"\(id) ownership")
                XCTAssertEqual(mine.kept.map { [mine.startSample + $0.lowerBound,mine.startSample + $0.upperBound] },want.presence16k,"\(id) presence16k")
                XCTAssertEqual(mine.gaps,want.gaps,"\(id) gaps")
                let floor = try XCTUnwrap(mine.floor,"\(id) has a floor")
                XCTAssertTrue((want.floorDb[0]...want.floorDb[1]).contains(floor),"\(id) floor \(floor) in \(want.floorDb)")
                let seconds = RecognitionFallback.seconds(frames:mine.active.filter { $0 }.count)
                XCTAssertTrue((want.activeSeconds[0]...want.activeSeconds[1]).contains(seconds),"\(id) activeSeconds \(seconds) in \(want.activeSeconds)")
                let windows = RecognitionFallback.fallbackWindows(kept:mine.kept,active:mine.active).map {
                    [Double(mine.startSample + $0.lowerBound) / 16,Double(mine.startSample + $0.upperBound) / 16]
                }
                XCTAssertEqual(windows,want.fallbackWindowsMs,"\(id) fallback windows")
                // No word is written whose midpoint lies in a noWords range of this track.
                for range in want.noWords {
                    for ms in [range[0],(range[0] + range[1]) / 2,range[1] - 1] where ms >= 0 {
                        XCTAssertFalse(MeetingTranscriber.writes(startMs:Int64(ms),endMs:Int64(ms),kept:mine.kept,startSample:mine.startSample),"\(id) writes at \(ms)")
                    }
                }
            }
            // D63 #1: each person's pooled active seconds lie in its band, and it fires (no VAD words) as the corpus says.
            for (person,band) in expected.personActiveSeconds {
                let frames = planned.filter { speakers[$0.id] == speaker(person) }.reduce(0) { $0 + $1.active.filter { $0 }.count }
                let seconds = RecognitionFallback.seconds(frames:frames)
                XCTAssertTrue((band[0]...band[1]).contains(seconds),"\(key) \(person) personActiveSeconds \(seconds) in \(band)")
                XCTAssertEqual(RecognitionFallback.fires(activeFrames:frames,vadWords:0),expected.fallback[person],"\(key) \(person) fallback")
            }
            // D63 #2: each person's gap ranges, and the turn cases in every grouper.
            let gaps = meeting.speakerGaps
            for (person,breaks) in expected.turnBreaksMs {
                XCTAssertEqual((gaps[speaker(person)] ?? []).map { [Double($0.lowerBound) / 16,Double($0.upperBound) / 16] },breaks,"\(key) \(person) turn breaks")
            }
            for turn in expected.turnCases {
                let words = turn.words.enumerated().map { LibraryTranscriptItem(speaker:speaker(turn.speaker),startMs:$0.element[0],endMs:$0.element[1],text:"w\($0.offset)") }
                XCTAssertEqual(MeetingPresentation.turns(words,gaps:gaps).map(\.items.count),turn.turns,"\(key) \(turn.words) meeting turns")
                XCTAssertEqual(LibraryTranscriptTurn.coalescing(words,gaps:gaps).map { $0.text.split(separator:" ").count },turn.turns,"\(key) \(turn.words) coalesced turns")
            }
            // D63 #3: the word midpoints, through the write rule on each track's kept time.
            for word in expected.wordMidpoints {
                let mine = try XCTUnwrap(planned.first { $0.id == word.track })
                XCTAssertEqual(MeetingTranscriber.writes(startMs:word.ms[0],endMs:word.ms[1],kept:mine.kept,startSample:mine.startSample),word.keep,"\(word.track) \(word.ms)")
            }
        }
    }

    /// D63 mutants the synthetic vectors cannot show: a midpoint rounded to whole ms (the
    /// a-long seam words), and a gap range closed at its end (a-long's [47995, 48005]).
    func testCorpusCatchesMidpointAndClosedRangeMutants() throws {
        let root = try sharedCorpus(), spec = try spec()
        let meeting = try call(root), key = meeting.id.uuidString.lowercased(), expected = try XCTUnwrap(spec.expected.sessions[key])
        let planned = try plan(meeting)
        let rounded = expected.wordMidpoints.contains { word in
            guard let mine = planned.first(where: { $0.id == word.track }) else { return false }
            let m = 16 * Int((Double(word.ms[0] + word.ms[1]) / 2).rounded(.up))
            return mine.kept.contains { mine.startSample + $0.lowerBound <= m && m < mine.startSample + $0.upperBound } != word.keep
        }
        XCTAssertTrue(rounded,"a midpoint rounded to whole ms must get a word midpoint wrong")
        let gaps = meeting.speakerGaps
        let closed = expected.turnCases.contains { turn in
            let own = gaps["track-" + turn.speaker] ?? gaps[turn.speaker] ?? []
            var sizes: [Int] = []
            for (index,word) in turn.words.enumerated() {
                let m2 = 8 * (word[0] + word[1]), m1 = index > 0 ? 8 * (turn.words[index-1][0] + turn.words[index-1][1]) : 0
                if index > 0 && !own.contains(where: { $0.lowerBound < max(m1,m2) && min(m1,m2) <= $0.upperBound }) { sizes[sizes.count-1] += 1 } else { sizes.append(1) }
            }
            return sizes != turn.turns
        }
        XCTAssertTrue(closed,"a gap range closed at its end must get a turn case wrong")
    }

    /// The corpus checks must fail on the mutations gocassini aefb64f1 guards against.
    func testCorpusChecksCatchPresenceAndFloorMutations() throws {
        let root = try sharedCorpus()
        let spec = try spec(), session = spec.sessions[0], meeting = try call(root)
        let expected = try XCTUnwrap(spec.expected.sessions[session.id])
        let ignored = failures(try plan(meeting,.gapsIgnored),session,expected)
        XCTAssertTrue(ignored.contains { $0.hasPrefix("a-long: recognizes") },"\(ignored)")
        XCTAssertTrue(ignored.contains { $0.hasPrefix("b-return: recognizes") },"\(ignored)")
        let gate = failures(try plan(meeting,.absoluteGate),session,expected)
        XCTAssertTrue(gate.contains { $0.hasPrefix("mic:") && $0.contains("outside speech") },"\(gate)")
    }
}
