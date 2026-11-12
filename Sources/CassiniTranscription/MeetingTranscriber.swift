// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniLibrary
import CassiniKit
import CassiniRecording
import CassiniWhistle

public enum MeetingTranscriber {
    public static func setStatus(directory: URL, id: UUID, status: String) throws {
        try MeetingMetadataWriter(directory: directory, id: id).transaction { metadata in
            var transcript = metadata["transcript"] as! [String:Any]
            if status == "queued", (transcript["status"] as? String) == "failed" {
                // Retry is a fresh recognition, not a resume of failed output.
                transcript["reference"] = NSNull()
            }
            // D67.2: a failed write-down references no words. Its partial transcript.json stays in the
            // folder, unreferenced, so no reader (or a published copy) shows partial words as stored.
            if status == "failed" { transcript["reference"] = NSNull() }
            if status != "none" { transcript.removeValue(forKey: "paused") }
            transcript["status"] = status; metadata["transcript"] = transcript
            metadata["etaMinutes"] = NSNull()
            metadata["error"] = status == "failed" ? ["id":"transcribe-failed", "action":"Try again"] : NSNull()
        }
    }
    public static func pauseForResume(directory: URL, id: UUID) throws {
        try MeetingMetadataWriter(directory:directory,id:id).transaction { metadata in
            guard var transcript = metadata["transcript"] as? [String:Any],
                  let status = transcript["status"] as? String, ["queued","running"].contains(status) else { return }
            transcript.removeValue(forKey: "paused")
            transcript["status"] = "queued"; metadata["transcript"] = transcript
            metadata["etaMinutes"] = NSNull(); metadata["error"] = NSNull()
        }
    }
    @discardableResult
    public static func stopForUser(directory: URL, id: UUID) throws -> Int64? {
        var stoppedRevision: Int64?
        try MeetingMetadataWriter(directory:directory,id:id).transaction(skippingUnchanged:true) { metadata in
            guard var transcript = metadata["transcript"] as? [String:Any],
                  let status = transcript["status"] as? String, ["none","queued","running"].contains(status) else { return }
            transcript["status"] = "none"; transcript["paused"] = true
            metadata["transcript"] = transcript
            metadata["etaMinutes"] = NSNull(); metadata["error"] = NSNull()
            stoppedRevision = (metadata["revision"] as? NSNumber)?.int64Value ?? 0
        }
        return stoppedRevision
    }
    /// One worker owns a meeting lock through both segmentation and recognition.
    /// Capture-owned session/audio files are only opened for reading.
    /// G11: one recognized range's word times, relative to its audio, clamped to that audio.
    /// A word starting past the end, or crossing it, keeps its text and ends at the end; it is
    /// never dropped. Non-finite, negative or reversed times are a recognizer failure.
    /// D55 (M9): the one placement at 16 kHz, the session sample where a track's recognizer input
    /// starts; an unknown offset is placed at 0 (and flagged as offsetsAssumedZero).
    static func placedStart(offsetMs: Double?) -> Int { Int(TrackPlacement.frame(ms:offsetMs ?? 0,rate:16000)) }
    /// Session milliseconds of a track-local 16 kHz sample (word times add the segment start here,
    /// and each word's start inside the segment in clamped).
    static func sessionMs(startSample: Int, local: Int) -> Int64 { Int64(startSample + local) * 1000 / 16000 }
    static func clamped(_ words: [WhistleTranscript.Word], startMs: Int64, lengthMs: Int64) throws -> [RecognitionFallback.Word] {
        try words.map { word in
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start else { throw TranscriptionFailure.runtime("invalid recognizer word timestamp") }
            let a = Int64((min(word.start,1e9) * 1000).rounded(.toNearestOrEven)), b = Int64((min(word.end,1e9) * 1000).rounded(.toNearestOrEven))
            let from = min(a,lengthMs)
            return .init(text:word.word,startMs:startMs + from,endMs:startMs + min(max(b,from),lengthMs))
        }
    }
    /// Called synchronously after each committed transcript sidecar, before the next publication.
    public static func run(directory inputDirectory: URL, engine: WhistleEngine, detector: SpeechDetector, me: String = "Me", others: String = "The others", uiLanguage: CassiniLanguage = .system, sidecarWritten: () -> Void = {}) throws {
        try run(directory:inputDirectory,detector:detector,model:"whistle",initialETA:0.15,me:me,others:others,uiLanguage:uiLanguage,sidecarWritten:sidecarWritten,recognize:engine.transcribe)
    }
    public static func run(directory inputDirectory: URL, detector: SpeechDetector, model: String,
                           initialETA: Double, initialLanguage: String = "auto", me: String = "Me", others: String = "The others", uiLanguage: CassiniLanguage = .system,
                           sidecarWritten: () -> Void = {},
                           recognize: ([Float]) throws -> WhistleTranscript) throws {
        var folderInfo = stat()
        guard lstat(inputDirectory.path, &folderInfo) == 0, folderInfo.st_mode & S_IFMT == S_IFDIR else { throw TranscriptionFailure.invalidMeeting }
        guard let canonical = realpath(inputDirectory.path, nil) else { throw TranscriptionFailure.invalidMeeting }
        let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true); free(canonical)
        let lockFD = open(directory.appendingPathComponent(".transcription.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw TranscriptionFailure.invalidMeeting }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw TranscriptionFailure.runtime("meeting is already being written down") }
        let scanner = LibraryScanner(root: directory.deletingLastPathComponent())
        guard let meeting = try scanner.scan().meetings.first(where: { $0.folder.path == directory.path }),
              !meeting.metadataReadOnly, meeting.state.lifecycle == .saved, !meeting.audioFiles.isEmpty,
              [.none,.queued,.running,.failed].contains(meeting.state.transcript) else { throw TranscriptionFailure.invalidMeeting }
        let writer = try MeetingMetadataWriter(directory: directory, id: meeting.id)
        do {
            let attemptStarted = ProcessInfo.processInfo.systemUptime
            try setStatus(directory: directory, id: meeting.id, status: "running")
            let received = meeting.state.origin == .received
            struct Track {
                /// D52 M15: planned from a first pass whose scratch is already released.
                /// D55 (M9): the session 16 kHz sample where the track starts (TrackPlacement).
                let url: URL; let sampleCount: Int; let speaker: TranscriptSpeaker; let startSample: Int
                /// Session milliseconds of a track-local 16 kHz sample.
                func ms(_ local: Int) -> Int64 { MeetingTranscriber.sessionMs(startSample:startSample,local:local) }
                /// Speech segments clipped to the half-open ranges this source owns.
                let segments: [SpeechSegment]
                let id: String
                /// Track-local 16 kHz sample ranges inside D52.2 presence and ownership.
                let kept: [Range<Int>]
                /// D52.4 R71 activity inside `kept`, measured while planning, and its whole active frames.
                let active: [Bool]; var activeFrames: Int { active.filter { $0 }.count }
                /// D56/D57: under 32 non-zero native 32 ms frames: never decoded or recognized.
                var silent = false
            }
            var tracks: [Track] = []
            let sources: [(URL, String, String, Double?, String?, Double?, [TrackPresence.Gap]?)]
            if received { sources = [(meeting.audioFiles[0], "original", "original", 0, nil, nil, nil)] }
            else {
                // The Library scanner already isolates damaged tracks and
                // safely salvages unsupported/missing manifests. Reuse those
                // exact sources instead of reopening every raw manifest path.
                sources = meeting.audioTracks.compactMap { track in
                    guard track.frameCount != 0 else { return nil }
                    let filenameID = String(track.url.deletingPathExtension().lastPathComponent.dropFirst("track-".count))
                    return (track.url,track.sourceID ?? filenameID,track.sourceKind ?? "media",track.startOffsetMs,track.sourceTrackID,track.endOffsetMs,presenceGaps(track))
                }
            }
            // D52 M1: one source becomes one speaker only while its spans are disjoint. Readers
            // derive the same speakers from the same tracks (TranscriptSpeaker.assign, D63 #2).
            let assigned = received ? [] : TranscriptSpeaker.assign(meeting.audioTracks,received:false,me:me,others:others)
            let speakerOf = Dictionary(assigned.map { ($0.track.url,$0.speaker) },uniquingKeysWith:{ first,_ in first })
            let separated = assigned.contains { $0.speaker.id.contains(":overlap:") }
            let ownership = received ? nil : OthersOwnership(events:meeting.captureEvents)
            // D56 and D67.3: the tracks left out as silent, a 0-frame (never-captured) track included,
            // in the meeting's track order.
            var silentTracks: [String] = []
            let trackOrder = meeting.audioTracks.map { $0.sourceID ?? String($0.url.deletingPathExtension().lastPathComponent.dropFirst("track-".count)) }
            if !received { silentTracks = meeting.audioTracks.filter { $0.frameCount == 0 }.map { $0.sourceID ?? String($0.url.deletingPathExtension().lastPathComponent.dropFirst("track-".count)) } }
            // D55 (M9): an unknown offset is placed at 0 and flagged on this attempt. D57: a silent
            // track is never placed, so it never sets the flag.
            var assumedZero = false
            for (url, id, kind, recorded, sourceTrackID, _, gaps) in sources {
                if recorded == nil { fputs("Cassini transcription: unknownStartOffset; using 0 for word times\n", stderr) }
                // The one placement at 16 kHz; presence and ownership edges are measured from it.
                let startSample = Self.placedStart(offsetMs:recorded)
                let offset = recorded.map { _ in Double(startSample) / 16 }
                let speaker = speakerOf[url] ?? TranscriptSpeaker.fromTrack(id: id, kind: kind, sourceTrackID:sourceTrackID, received: received, me: me, others: others)
                // D56/D57 (GNOME R76): each session.json track entry is judged on its own native
                // samples. A silent one is left out of recognition and its fallback; it stays in
                // the meeting and the mixdown, and captureOutcome is unchanged.
                if !received, Self.isSilent(wav:url) {
                    silentTracks.append(id)
                    var track = Track(url: url, sampleCount: 0, speaker: speaker, startSample: startSample, segments: [], id: id, kept: [], active: [])
                    track.silent = true; tracks.append(track)
                    continue
                }
                if !received && recorded == nil { assumedZero = true }
                let audio = try SegmentedAudio(url: url, detector: detector)
                var segments = audio.segments
                var kept = audio.sampleCount > 0 ? [0..<audio.sampleCount] : []
                // D49/D33 seams and D52.2 presence: audio outside this source's ownership,
                // or inside a stored gap range, is not recognized.
                if let offset, let owned = ownedWindows(offsetMs:offset,sampleCount:audio.sampleCount,kind:kind,gaps:gaps,ownership:ownership) {
                    kept = keptRanges(owned,offsetMs:offset,sampleCount:audio.sampleCount)
                    segments = segments.flatMap { segment in
                        owned.compactMap { range -> SpeechSegment? in
                            // D52.2 presence grid: [a,b) ms covers samples [ceil(16a-1e-6), ceil(16b-1e-6)).
                            let a = max(segment.startSample,Int(((range.0-offset)*16 - 1e-6).rounded(.up)))
                            let b = min(segment.endSample,Int(((range.1-offset)*16 - 1e-6).rounded(.up)))
                            return b > a ? .init(startSample:a,endSample:b,reason:segment.reason) : nil
                        }
                    }
                }
                // D52.4 R71: activity inside this track's present, owned time (never the mix).
                let meter = try activity(audio,kept:kept)
                let active = meter.active()
                tracks.append(.init(url: url, sampleCount: audio.sampleCount, speaker: speaker, startSample: startSample, segments: segments, id: id, kept: kept,
                                    active: active))
                // The planning scratch is released here (end of scope), before the next track.
            }
            let silent = Set(silentTracks)
            var listed = Set<String>()
            silentTracks = trackOrder.filter { silent.contains($0) && listed.insert($0).inserted }
            // A new model must regenerate partial output rather than attribute
            // another/unknown recognizer's words to the selected model.
            let resumes = ([.queued,.running].contains(meeting.state.transcript) || meeting.transcriptPaused) && meeting.transcriptModel == model
            let previous = resumes ? meeting.writtenTranscriptItems : [] // D24: never merged ids
            // D67.2 (#139 review): a failed attempt's partial words wait, unreferenced, in
            // transcript.json. Until this attempt has written as many words, a running publish
            // must not replace them, so a retry that fails early never loses the longer snapshot;
            // a completed attempt replaces it. Only an unreferenced body is retained: a referenced
            // one is resumed through `previous` (same model) or regenerated (a new model).
            let retained = meeting.transcriptReferenced ? 0 : LibraryScanner.sidecarWordCount(folder:directory)
            // Whether this attempt has written transcript.json yet. Until it has, the stored
            // reference stays as it was (null after a failure), so the retained words of a failed
            // attempt never become visible again under this attempt's model.
            var wroteSidecar = false
            var progress = TranscriptProgress(previous:previous,speakers:tracks.map { $0.speaker.id })
            var items: [TranscriptProgress.Item] = [], language = initialLanguage, elapsed: Double = 0, processed: Double = 0
            if resumes, initialLanguage == "auto", let previousLanguage = meeting.transcriptLanguage { language = previousLanguage }
            var remaining = tracks.reduce(0.0) { sum, track in sum + track.segments.reduce(0.0) { $0 + Double($1.endSample - $1.startSample) / 16000 } }
            let reference: [String:Any] = ["kind":"sidecar", "file":"transcript.json", "format":"cassini.words.v1"]
            var fallbackDecisions: [[String:Any]] = []
            func publish(status: String) throws {
                let ordered = progress.published(items,complete:status == "done")
                struct Body: Encodable { let language: String; let items: [LibraryTranscriptItem] }
                // D53.2: an unknown language is written as "und", never the "auto" request.
                let data = try JSONEncoder().encode(Body(language: TranscriptLanguage.written(language), items: ordered))
                guard data.count <= 64 * 1024 * 1024 else { throw TranscriptionFailure.runtime("transcript size limit") }
                if status == "done" || ordered.count >= retained { try atomicTranscript(data, directory: directory); wroteSidecar = true; sidecarWritten() }
                let factor = processed > 0 ? elapsed / processed : initialETA
                let eta = Int64(ceil(max(0, remaining) * factor / 60))
                try writer.transaction { metadata in
                    // D47/D56: edit the stored transcript object, so members this app does
                    // not know survive; the reference is this attempt's own sidecar.
                    var transcript = metadata["transcript"] as? [String:Any] ?? [:]
                    transcript.removeValue(forKey: "paused")
                    transcript["status"] = status; transcript["model"] = model
                    if wroteSidecar { transcript["reference"] = reference }
                    metadata["transcript"] = transcript
                    metadata["etaMinutes"] = status == "running" ? eta : NSNull()
                    metadata["error"] = NSNull()
                    var speakers = metadata["speakers"] as? [[String:Any]] ?? []
                    for track in tracks where !speakers.contains(where: { ($0["id"] as? String) == track.speaker.id }) {
                        speakers.append(["id":track.speaker.id, "name":track.speaker.name as Any? ?? NSNull(), "provenance":track.speaker.name == nil ? "unnamed" : "source", "colourIndex":speakers.count])
                    }
                    // D47/D50: producing words also writes their labels in the
                    // writer's language. Recompute unnamed numbers as partials
                    // gain earlier turns (including after resume); readers and
                    // metadata-only edits never rewrite these stored labels.
                    var seen=Set<String>()
                    let spoken=ordered.compactMap {seen.insert($0.speaker).inserted ? $0.speaker : nil}
                    for (number,id) in spoken.enumerated() {
                        guard let index=speakers.firstIndex(where:{$0["id"] as? String == id}) else {continue}
                        speakers[index]["label"]=(speakers[index]["name"] as? String) ?? LibraryLocalization.shared.text("common.speaker.unnamed",["n":String(number+1)],language:uiLanguage)
                    }
                    metadata["speakers"] = speakers
                    if status == "done" {
                        // D28 writingDown facts of this successful attempt (the schema requires
                        // wallDurationMs, resumed and speakerSeparation). Known facts are replaced by
                        // each completed attempt; unknown fields survive. Mac has no speaker separation.
                        var details = metadata["recordingDetails"] as? [String:Any] ?? [:]
                        var writing = details["writingDown"] as? [String:Any] ?? [:]
                        writing["wallDurationMs"] = Int64(max(0,ProcessInfo.processInfo.systemUptime - attemptStarted) * 1000)
                        writing["resumed"] = resumes
                        writing["speechSegments"] = tracks.reduce(0) { $0 + $1.segments.count }
                        writing["speakerSeparation"] = ["status":"skipped","reason":"unavailable"]
                        // D52.3d: set only when separation actually ran.
                        if separated { writing["sourceSpansSeparated"] = true } else { writing.removeValue(forKey:"sourceSpansSeparated") }
                        // D52.4 R71: this attempt's per-track fallback decisions (additive, not displayed).
                        if fallbackDecisions.isEmpty { writing.removeValue(forKey:"recognitionFallback") }
                        else {
                            writing["recognitionFallback"] = ["method":"vadFreeWindows","windowMs":RecognitionFallback.window*1000/RecognitionFallback.rate,
                                "overlapMs":RecognitionFallback.overlap*1000/RecognitionFallback.rate,"tracks":fallbackDecisions]
                        }
                        // D56: the tracks this attempt left out as silent; replaced each attempt, omitted when empty.
                        if silentTracks.isEmpty { writing.removeValue(forKey:"silentTracks") } else { writing["silentTracks"] = silentTracks }
                        // D55 (M9): replaced with each attempt; absent unless an offset was assumed.
                        if assumedZero { writing["offsetsAssumedZero"] = true } else { writing.removeValue(forKey:"offsetsAssumedZero") }
                        details["writingDown"] = writing
                        metadata["recordingDetails"] = details
                    }
                }
            }
            try publish(status: "running")
            /// Recognise one range of a track; word times are clamped to its own audio (G11).
            func words(_ track: Track, _ audio: SegmentedAudio, _ segment: SpeechSegment) throws -> [RecognitionFallback.Word] {
                let began = ProcessInfo.processInfo.systemUptime, samples = try audio.samples(segment)
                let result = try recognize(samples)
                if ["auto","und",""].contains(language) { language = result.language }
                let start = track.ms(segment.startSample), length = Int64(samples.count) * 1000 / 16000
                let out = try Self.clamped(result.words ?? [],startMs:start,lengthMs:length)
                let speech = Double(samples.count) / 16000
                processed += speech; remaining = max(0,remaining - speech); elapsed += max(0, ProcessInfo.processInfo.systemUptime - began)
                return out
            }
            /// D63 #3: on every path (VAD and fallback), a word is written only when its midpoint lies
            /// in its track's kept time; a word clamped to zero length at the end of presence is not.
            func append(_ words: [RecognitionFallback.Word], track index: Int) {
                for word in words where Self.writes(startMs:word.startMs,endMs:word.endMs,kept:tracks[index].kept,startSample:tracks[index].startSample) { items.append(.init(word: .init(speaker: tracks[index].speaker.id, startMs: word.startMs, endMs: word.endMs, text: word.text), track: index, ordinal: items.count)) }
            }
            // D63 #1: the R71 tests pool every non-silent track of one person (the same speaker id
            // across rejoins; an R64 overlap lane is its own). A person with enough pooled active audio
            // holds its VAD words until they reach FEW_WORDS over all its tracks; if they never do, its
            // last track decides, and each of its tracks is decoded in windows with its own margin.
            var personTracks: [String:[Int]] = [:]
            for (index,track) in tracks.enumerated() where !track.silent { personTracks[track.speaker.id,default:[]].append(index) }
            let candidate = personTracks.mapValues { indices in indices.reduce(0) { $0 + tracks[$1].activeFrames } >= RecognitionFallback.minActiveFrames }
            var personVad: [String:Int] = [:], released = Set<String>(), trackVad = [Int](repeating:0,count:tracks.count)
            var held: [Int:[RecognitionFallback.Word]] = [:], heldEnd: [Int:Int64] = [:], waiting = Set<Int>()
            var decisions: [(index: Int, track: RecognitionFallback.PersonTrack)] = [], fallbackOf: [Int:[RecognitionFallback.Word]] = [:]
            /// A person reached FEW_WORDS: its held VAD words are written, and its finished tracks finish.
            func release(_ person: String) {
                released.insert(person)
                for index in personTracks[person] ?? [] {
                    if let words = held.removeValue(forKey:index) { append(words,track:index) }
                    if let end = heldEnd[index] { progress.advance(track:index,to:end) }
                    if waiting.remove(index) != nil { progress.finish(track:index) }
                }
            }
            /// One track's VAD pass. The track's scratch is released when this returns (M15).
            func vadPass(_ index: Int) throws {
                let track = tracks[index], person = track.speaker.id
                let audio = try SegmentedAudio(url: track.url)
                guard audio.sampleCount == track.sampleCount else { throw TranscriptionFailure.audioFormat }
                if candidate[person] == true && !released.contains(person) { held[index] = [] }
                for segment in track.segments {
                    let found = try words(track,audio,segment)
                    trackVad[index] += found.count; personVad[person,default:0] += found.count
                    let end = track.ms(segment.endSample)
                    if held[index] == nil { append(found,track:index); progress.advance(track:index,to:end); try publish(status: "running"); continue }
                    held[index]! += found; heldEnd[index] = end
                    if personVad[person]! >= RecognitionFallback.fewWords { release(person); try publish(status: "running") }
                }
            }
            /// R71 windows of one track of a firing person, decoded and merged across seams.
            func fallbackWords(_ index: Int) throws -> [RecognitionFallback.Word] {
                let track = tracks[index]
                let audio = try SegmentedAudio(url: track.url)
                guard audio.sampleCount == track.sampleCount else { throw TranscriptionFailure.audioFormat }
                let windows = RecognitionFallback.fallbackWindows(kept:track.kept,active:track.active)
                remaining += Double(windows.reduce(0) { $0 + $1.count }) / 16000
                var fallback: [RecognitionFallback.Word] = [], previousEnd: Int?
                for window in windows {
                    let segment = SpeechSegment(startSample:window.lowerBound,endSample:window.upperBound,reason:"noVadWindow")
                    let base = track.ms(window.lowerBound)
                    let kept = RecognitionFallback.energetic(try words(track,audio,segment),samples:try audio.samples(segment),baseMs:base)
                    if let previousEnd, window.lowerBound < previousEnd {
                        fallback = RecognitionFallback.mergeSeam(fallback,kept,windowStartMs:base,overlapMs:Int64((previousEnd - window.lowerBound) * 1000 / 16000))
                    } else { fallback += kept }
                    previousEnd = window.upperBound
                }
                return fallback
            }
            for (index, track) in tracks.enumerated() {
                if track.silent { progress.finish(track:index); continue }
                try vadPass(index)
                let person = track.speaker.id
                guard held[index] != nil else { progress.finish(track:index); try publish(status:"running"); continue }
                waiting.insert(index)
                guard index == personTracks[person]?.last else { continue }
                // The person's last track, still under FEW_WORDS pooled: it fires. Each of its tracks
                // is decoded in windows (one scratch at a time) and keeps its own margin.
                for member in personTracks[person] ?? [] { fallbackOf[member] = try fallbackWords(member) }
                let verdict = RecognitionFallback.decide((personTracks[person] ?? []).map { member in
                    .init(trackId:tracks[member].id,speaker:person,activeFrames:tracks[member].activeFrames,vadWords:trackVad[member],fallbackWords:fallbackOf[member]!.count)
                })
                for (member,entry) in zip(personTracks[person] ?? [],verdict.entries) {
                    append(entry.used ? fallbackOf[member]! : held.removeValue(forKey:member) ?? [],track:member)
                    held[member] = nil
                    if let end = heldEnd[member] { progress.advance(track:member,to:end) }
                    waiting.remove(member); progress.finish(track:member)
                }
                decisions += (personTracks[person] ?? []).map { member in
                    (member,.init(trackId:tracks[member].id,speaker:person,activeFrames:tracks[member].activeFrames,vadWords:trackVad[member],fallbackWords:fallbackOf[member]!.count))
                }
                fallbackOf = [:]
                try publish(status:"running")
            }
            // D52.4 R71 provenance (additive, not displayed): every firing person's tracks, in track order.
            fallbackDecisions = RecognitionFallback.decide(decisions.sorted { $0.index < $1.index }.map(\.track)).entries.map(\.json)
            try publish(status: "done")
        } catch { try? setStatus(directory: directory, id: meeting.id, status: "failed"); throw error }
    }
    /// D56/D57 (GNOME R76): a track is silent with fewer than 32 non-zero frames. Frames are
    /// floor(rate × 32 / 1000) native samples, non-overlapping from the file's first sample, and a
    /// trailing partial frame never counts; a frame is non-zero if any sample on any channel is
    /// != 0 (DC counts). Reads the WAV directly and stops at the 32nd frame. A file this reader
    /// does not understand is never called silent.
    ///
    /// Like the decoder and the Library scanner, a Cassini WAV (the canonical 44-byte header)
    /// is judged on its physical complete frames: a recovered track's checkpoint header can
    /// declare fewer bytes than were written, or more than exist. Other layouts keep their
    /// declared size, bounded by what is on disk.
    static let silentFrameLimit = 32
    static func isSilent(wav url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom:url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount:12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8) else { return false }
        func u32(_ d: Data, _ at: Int) -> Int { Int(d[d.startIndex+at]) | Int(d[d.startIndex+at+1]) << 8 | Int(d[d.startIndex+at+2]) << 16 | Int(d[d.startIndex+at+3]) << 24 }
        func u16(_ d: Data, _ at: Int) -> Int { Int(d[d.startIndex+at]) | Int(d[d.startIndex+at+1]) << 8 }
        var channels = 0, rate = 0, bits = 0, fmtSize = 0, offset: UInt64 = 12
        while let chunk = try? { try handle.seek(toOffset:offset); return try handle.read(upToCount:8) }(), chunk.count == 8 {
            let size = u32(chunk,4), body = offset + 8
            if chunk.prefix(4) == Data("fmt ".utf8) {
                guard size >= 16, let fmt = try? handle.read(upToCount:16), fmt.count == 16, u16(fmt,0) == 1 || u16(fmt,0) == 0xFFFE else { return false }
                channels = u16(fmt,2); rate = u32(fmt,4); bits = u16(fmt,14); fmtSize = size
            } else if chunk.prefix(4) == Data("data".utf8) {
                guard channels > 0, rate > 0, bits == 16 else { return false }
                let frameBytes = rate * 32 / 1000 * channels * 2
                guard frameBytes > 0 else { return false }
                // nil: read to the end of the file, as the decoder does for a Cassini WAV.
                var remaining: Int? = fmtSize == 16 && body == 44 ? nil : size / frameBytes
                var found = 0
                while remaining.map({ $0 > 0 }) ?? true {
                    let count = min(remaining ?? 256,256)
                    guard let block = try? handle.read(upToCount:count * frameBytes) else { break }
                    // A short read still holds complete frames; only a trailing partial frame is dropped.
                    let complete = block.count / frameBytes
                    found += block.withUnsafeBytes { raw -> Int in
                        let samples = raw.bindMemory(to:Int16.self), per = frameBytes / 2
                        return (0..<complete).filter { f in samples[(f*per)..<((f+1)*per)].contains { $0 != 0 } }.count
                    }
                    if found >= silentFrameLimit { return false }
                    if complete < count { break }
                    remaining = remaining.map { $0 - count }
                }
                return true
            }
            offset = body + UInt64(size) + UInt64(size & 1)
        }
        return false
    }
    /// Stored gap ranges as presence gaps. Gap frames are at the track's own rate;
    /// they are carried as milliseconds.
    static func presenceGaps(_ track: LibraryAudioTrack) -> [TrackPresence.Gap]? { presenceGaps(track.gaps,sampleRate:track.sampleRate) }
    static func presenceGaps(_ gaps: [TrackPresence.Gap]?, sampleRate: Int?) -> [TrackPresence.Gap]? {
        let rate = Double(sampleRate ?? 48000)
        return gaps?.map { TrackPresence.Gap(atMs:$0.atMs,durationMs:$0.frames.map { Double($0)*1000/rate } ?? $0.durationMs,frames:nil,kind:$0.kind) }
    }
    /// The session-millisecond windows of a 16 kHz track that are recognized: owned
    /// time (D49/D33) minus stored gap ranges (D52.2; prefix and padding are absence).
    /// Unknown time is kept because its audio exists. nil keeps the whole track.
    static func ownedWindows(offsetMs offset: Double, sampleCount: Int, kind: String, gaps: [TrackPresence.Gap]?, ownership: OthersOwnership?) -> [(Double,Double)]? {
        let end = offset + Double(sampleCount)/16
        let mask = ownership.map { $0.owned(kind:kind,startMs:offset,endMs:end).map { (start:$0.0,end:$0.1) } }
        return ownedWindows(offsetMs:offset,sampleCount:sampleCount,gaps:gaps,mask:mask)
    }
    /// The same, with the ownership already resolved to session-millisecond windows.
    static func ownedWindows(offsetMs offset: Double, sampleCount: Int, gaps: [TrackPresence.Gap]?, mask: [TrackPresence.Window]?) -> [(Double,Double)]? {
        guard mask != nil || gaps?.isEmpty == false else { return nil }
        let presence = TrackPresence.windows(startOffsetMs:offset,sampleRate:16000,frames:UInt64(sampleCount),gaps:gaps,ownership:mask)
        // Present and unknown windows are disjoint; together they are the kept time.
        return (presence.present + presence.unknown).sorted { $0.start < $1.start }.map { ($0.start,$0.end) }
    }
    /// D63 #3: a word is written only when its exact midpoint M = 8 × (startMs + endMs), in 16 kHz
    /// session samples, lies in one of its track's kept ranges (owned present-or-unknown time,
    /// track-local from the D55 placement `startSample`), compared in session samples. A word
    /// clamped to zero length at the end of presence (G11) lands on the end and is not written.
    static func writes(startMs: Int64, endMs: Int64, kept: [Range<Int>], startSample: Int) -> Bool {
        let m = 8 * (Int(startMs) + Int(endMs))
        return kept.contains { startSample + $0.lowerBound <= m && m < startSample + $0.upperBound }
    }
    /// Track-local 16 kHz sample ranges of `owned`, on the D52.2 presence grid.
    static func keptRanges(_ owned: [(Double,Double)], offsetMs offset: Double, sampleCount: Int) -> [Range<Int>] {
        owned.compactMap { range -> Range<Int>? in
            let a = max(0,Int(((range.0-offset)*16 - 1e-6).rounded(.up))), b = min(sampleCount,Int(((range.1-offset)*16 - 1e-6).rounded(.up)))
            return b > a ? a..<b : nil
        }
    }
    /// D52.4 R71 activity of one track: time outside `kept` is fed as silence.
    static func activity(_ audio: SegmentedAudio, kept: [Range<Int>]) throws -> RecognitionFallback.ActivityMeter {
        var meter = RecognitionFallback.ActivityMeter(), cursor = 0
        for range in kept {
            if range.lowerBound > cursor { meter.feedSilence(range.lowerBound - cursor) }
            var at = range.lowerBound
            while at < range.upperBound {
                let end = min(range.upperBound,at + 240000)
                meter.feed(try audio.samples(.init(startSample:at,endSample:end,reason:"activity"))); at = end
            }
            cursor = range.upperBound
        }
        return meter
    }
    private static func atomicTranscript(_ data: Data, directory: URL) throws {
        let temp = directory.appendingPathComponent(".transcript-" + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TranscriptionFailure.invalidMeeting }
        defer { try? FileManager.default.removeItem(at: temp) }
        let stream = try FileHandle(forWritingTo: temp); defer { try? stream.close() }
        try stream.write(contentsOf: data); try stream.synchronize()
        guard rename(temp.path, directory.appendingPathComponent("transcript.json").path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
