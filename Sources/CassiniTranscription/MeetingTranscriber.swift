// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniLibrary
import CassiniKit
import CassiniRecording
import CassiniWhistle

public struct TranscriptSpeaker: Sendable {
    public let id: String
    public let name: String?
    public static func fromTrack(id: String, kind: String, sourceTrackID: String? = nil, received: Bool = false, me: String = "Me", others: String = "The others") -> Self {
        if received { return .init(id: "track-original", name: nil) }
        if ["microphone", "local"].contains(kind) { return .init(id: "me", name: me) }
        if kind == "system" { return .init(id: "others", name: others) }
        let identity = sourceTrackID ?? id
        let safe = !identity.isEmpty && identity.utf8.count <= 195 && identity.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,95].contains($0)
        }
        let suffix = safe ? identity : "opaque-" + SHA256.hash(data:Data(identity.utf8)).map { String(format:"%02x",$0) }.joined()
        return .init(id: "track-" + suffix, name: nil)
    }
}
public enum MeetingTranscriber {
    public static func setStatus(directory: URL, id: UUID, status: String) throws {
        try MeetingMetadataWriter(directory: directory, id: id).transaction { metadata in
            var transcript = metadata["transcript"] as! [String:Any]
            if status == "queued", (transcript["status"] as? String) == "failed" {
                // Retry is a fresh recognition, not a resume of failed output.
                transcript["reference"] = NSNull()
            }
            transcript["status"] = status; metadata["transcript"] = transcript
            metadata["etaMinutes"] = NSNull()
            metadata["error"] = status == "failed" ? ["id":"transcribe-failed", "action":"Try again"] : NSNull()
        }
    }
    public static func pauseForResume(directory: URL, id: UUID) throws {
        try MeetingMetadataWriter(directory:directory,id:id).transaction { metadata in
            guard var transcript = metadata["transcript"] as? [String:Any],
                  let status = transcript["status"] as? String, ["queued","running"].contains(status) else { return }
            transcript["status"] = "queued"; metadata["transcript"] = transcript
            metadata["etaMinutes"] = NSNull(); metadata["error"] = NSNull()
        }
    }
    /// One worker owns a meeting lock through both segmentation and recognition.
    /// Capture-owned session/audio files are only opened for reading.
    /// G11: one recognized range's word times, relative to its audio, clamped to that audio.
    /// A word starting past the end, or crossing it, keeps its text and ends at the end; it is
    /// never dropped. Non-finite, negative or reversed times are a recognizer failure.
    static func clamped(_ words: [WhistleTranscript.Word], startMs: Int64, lengthMs: Int64) throws -> [RecognitionFallback.Word] {
        try words.map { word in
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start else { throw TranscriptionFailure.runtime("invalid recognizer word timestamp") }
            let a = Int64((min(word.start,1e9) * 1000).rounded(.toNearestOrEven)), b = Int64((min(word.end,1e9) * 1000).rounded(.toNearestOrEven))
            let from = min(a,lengthMs)
            return .init(text:word.word,startMs:startMs + from,endMs:startMs + min(max(b,from),lengthMs))
        }
    }
    public static func run(directory inputDirectory: URL, engine: WhistleEngine, detector: SpeechDetector, me: String = "Me", others: String = "The others", uiLanguage: CassiniLanguage = .system) throws {
        try run(directory:inputDirectory,detector:detector,model:"whistle",initialETA:0.15,me:me,others:others,uiLanguage:uiLanguage,recognize:engine.transcribe)
    }
    public static func run(directory inputDirectory: URL, detector: SpeechDetector, model: String,
                           initialETA: Double, initialLanguage: String = "auto", me: String = "Me", others: String = "The others", uiLanguage: CassiniLanguage = .system,
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
                let url: URL; let sampleCount: Int; let speaker: TranscriptSpeaker; let offset: Int64
                /// Speech segments clipped to the half-open ranges this source owns.
                let segments: [SpeechSegment]
                let id: String
                /// Track-local 16 kHz sample ranges inside D52.2 presence and ownership.
                let kept: [Range<Int>]
                /// D52.4 R71 activity inside `kept`, measured while planning.
                let active: [Bool]; let activeSeconds: Double
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
                    // Gap frames are at the track's own rate; carry them as milliseconds.
                    let rate = Double(track.sampleRate ?? 48000)
                    let gaps = track.gaps?.map { TrackPresence.Gap(atMs:$0.atMs,durationMs:$0.frames.map { Double($0)*1000/rate } ?? $0.durationMs,frames:nil,kind:$0.kind) }
                    return (track.url,track.sourceID ?? filenameID,track.sourceKind ?? "media",track.startOffsetMs,track.sourceTrackID,track.endOffsetMs,gaps)
                }
            }
            // D52 M1: one source becomes one speaker only while its spans are disjoint.
            let lengths = Dictionary(meeting.audioTracks.map { ($0.url,($0.frameCount,$0.sampleRate)) },uniquingKeysWith:{ first,_ in first })
            let lanes = SourceSpanLanes.assign(sources.compactMap { url, id, kind, offset, sourceTrackID, end, _ in
                let base = TranscriptSpeaker.fromTrack(id:id,kind:kind,sourceTrackID:sourceTrackID,received:received,me:me,others:others).id
                guard base.hasPrefix("track-"), !received else { return nil }
                let length = lengths[url]
                return .init(id:id,base:base,startMs:offset,endMs:offset == nil ? nil : end,frames:length?.0,sampleRate:length?.1)
            })
            let separated = lanes.values.contains { $0.contains(":overlap:") }
            let ownership = received ? nil : OthersOwnership(events:meeting.captureEvents)
            var silentTracks: [String] = []
            for (url, id, kind, offset, sourceTrackID, _, gaps) in sources {
                if offset == nil { fputs("Cassini transcription: unknownStartOffset; using 0 for word times\n", stderr) }
                var speaker = TranscriptSpeaker.fromTrack(id: id, kind: kind, sourceTrackID:sourceTrackID, received: received, me: me, others: others)
                if let lane = lanes[id] { speaker = .init(id:lane,name:speaker.name) }
                // D56/D57 (GNOME R76): each session.json track entry is judged on its own native
                // samples. A silent one is left out of recognition and its fallback; it stays in
                // the meeting and the mixdown, and captureOutcome is unchanged.
                if !received, Self.isSilent(wav:url) {
                    silentTracks.append(id)
                    var track = Track(url: url, sampleCount: 0, speaker: speaker, offset: Int64(floor(offset ?? 0)), segments: [], id: id, kept: [], active: [], activeSeconds: 0)
                    track.silent = true; tracks.append(track)
                    continue
                }
                let audio = try SegmentedAudio(url: url, detector: detector)
                var segments = audio.segments
                var kept = audio.sampleCount > 0 ? [0..<audio.sampleCount] : []
                // D49/D33 seams: audio outside this source's ownership is not recognized.
                if let offset, ownership != nil || gaps?.isEmpty == false {
                    let end = offset + Double(audio.sampleCount)/16
                    // D52.2: recognise only owned time, minus stored gap ranges (prefix and
                    // padding are absence); unknown time is kept because its audio exists.
                    let mask = ownership.map { $0.owned(kind:kind,startMs:offset,endMs:end).map { (start:$0.0,end:$0.1) } }
                    let presence = TrackPresence.windows(startOffsetMs:offset,sampleRate:16000,frames:UInt64(audio.sampleCount),gaps:gaps,ownership:mask)
                    // Present and unknown windows are disjoint; together they are the kept time.
                    let owned = (presence.present + presence.unknown).sorted { $0.start < $1.start }.map { ($0.start,$0.end) }
                    kept = owned.compactMap { range -> Range<Int>? in
                        let a = max(0,Int(((range.0-offset)*16 - 1e-6).rounded(.up))), b = min(audio.sampleCount,Int(((range.1-offset)*16 - 1e-6).rounded(.up)))
                        return b > a ? a..<b : nil
                    }
                    segments = segments.flatMap { segment in
                        owned.compactMap { range -> SpeechSegment? in
                            // D52.2 presence grid: [a,b) ms covers samples [ceil(16a-1e-6), ceil(16b-1e-6)).
                            let a = max(segment.startSample,Int(((range.0-offset)*16 - 1e-6).rounded(.up)))
                            let b = min(segment.endSample,Int(((range.1-offset)*16 - 1e-6).rounded(.up)))
                            return b > a ? .init(startSample:a,endSample:b,reason:segment.reason) : nil
                        }
                    }
                }
                // D56 (R75, gocassini's rule): a track with fewer than 32 non-zero 32 ms frames
                // (under 1 s of sound) is left out of recognition and its fallback. It stays in
                // the mixdown; captureOutcome is unchanged, since zeros are received audio.
                // D52.4 R71: activity inside this track's present, owned time (never the mix).
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
                let active = meter.active()
                tracks.append(.init(url: url, sampleCount: audio.sampleCount, speaker: speaker, offset: Int64(floor(offset ?? 0)), segments: segments, id: id, kept: kept,
                                    active: active, activeSeconds: meter.activeSeconds(active)))
                // The planning scratch is released here (end of scope), before the next track.
            }
            // A new model must regenerate partial output rather than attribute
            // another/unknown recognizer's words to the selected model.
            let resumes = [.queued,.running].contains(meeting.state.transcript) && meeting.transcriptModel == model
            let previous = resumes ? meeting.transcriptItems : []
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
                try atomicTranscript(data, directory: directory)
                let factor = processed > 0 ? elapsed / processed : initialETA
                let eta = Int64(ceil(max(0, remaining) * factor / 60))
                try writer.transaction { metadata in
                    // D47/D56: edit the stored transcript object, so members this app does
                    // not know survive; the reference is this attempt's own sidecar.
                    var transcript = metadata["transcript"] as? [String:Any] ?? [:]
                    transcript["status"] = status; transcript["reference"] = reference; transcript["model"] = model
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
                let start = track.offset + Int64(segment.startSample * 1000 / 16000), length = Int64(samples.count) * 1000 / 16000
                let out = try Self.clamped(result.words ?? [],startMs:start,lengthMs:length)
                let speech = Double(samples.count) / 16000
                processed += speech; remaining = max(0,remaining - speech); elapsed += max(0, ProcessInfo.processInfo.systemUptime - began)
                return out
            }
            func append(_ words: [RecognitionFallback.Word], track index: Int) {
                for word in words { items.append(.init(word: .init(speaker: tracks[index].speaker.id, startMs: word.startMs, endMs: word.endMs, text: word.text), track: index, ordinal: items.count)) }
            }
            for (index, track) in tracks.enumerated() {
                if track.silent { progress.finish(track:index); continue }
                // D52 M15: one track's scratch at a time; the same deterministic decode as planning.
                let audio = try SegmentedAudio(url: track.url)
                guard audio.sampleCount == track.sampleCount else { throw TranscriptionFailure.audioFormat }
                let active = track.active, activeSeconds = track.activeSeconds
                // A track with plenty of active audio holds its VAD words until it reaches the threshold.
                var held: [RecognitionFallback.Word]? = activeSeconds >= RecognitionFallback.minActiveSeconds ? [] : nil
                var heldEnd: Int64?, vadWords = 0
                for segment in track.segments {
                    let found = try words(track,audio,segment)
                    vadWords += found.count
                    let end = track.offset + Int64(segment.endSample * 1000 / 16000)
                    if held == nil { append(found,track:index); progress.advance(track:index,to:end); try publish(status: "running"); continue }
                    held! += found; heldEnd = end
                    if vadWords >= RecognitionFallback.fewWords {
                        append(held!,track:index); held = nil
                        progress.advance(track:index,to:end); try publish(status: "running")
                    }
                }
                if let vad = held {
                    // Active 15 s windows inside the kept ranges, so none crosses a gap or ownership edge.
                    let needed = Int((0.5 * 16000 / 512.0).rounded(.up))
                    let windows = track.kept.flatMap { range in
                        RecognitionFallback.windowBounds(range.count).map { (range.lowerBound + $0.lowerBound)..<(range.lowerBound + $0.upperBound) }
                    }.filter { w in
                        let a = w.lowerBound / 512, b = min(active.count,(w.upperBound + 511) / 512)
                        return a < b && active[a..<b].filter { $0 }.count >= needed
                    }
                    remaining += Double(windows.reduce(0) { $0 + $1.count }) / 16000
                    var fallback: [RecognitionFallback.Word] = [], previousEnd: Int?
                    for window in windows {
                        let segment = SpeechSegment(startSample:window.lowerBound,endSample:window.upperBound,reason:"noVadWindow")
                        let base = track.offset + Int64(window.lowerBound * 1000 / 16000)
                        let kept = RecognitionFallback.energetic(try words(track,audio,segment),samples:try audio.samples(segment),baseMs:base)
                        if let previousEnd, window.lowerBound < previousEnd {
                            fallback = RecognitionFallback.mergeSeam(fallback,kept,windowStartMs:base,overlapMs:Int64((previousEnd - window.lowerBound) * 1000 / 16000))
                        } else { fallback += kept }
                        previousEnd = window.upperBound
                    }
                    let used = fallback.count >= RecognitionFallback.need(vadWords)
                    // The fallback replaces the VAD words only past the margin; never both.
                    append(used ? fallback : vad,track:index)
                    fallbackDecisions.append(["trackId":track.id,"vadWords":vadWords,"fallbackWords":fallback.count,
                                              "activeSeconds":(activeSeconds * 1000).rounded() / 1000,"used":used])
                    if let heldEnd { progress.advance(track:index,to:heldEnd) }
                }
                progress.finish(track:index)
                try publish(status:"running")
            }
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
    private static func atomicTranscript(_ data: Data, directory: URL) throws {
        let temp = directory.appendingPathComponent(".transcript-" + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TranscriptionFailure.invalidMeeting }
        defer { try? FileManager.default.removeItem(at: temp) }
        let stream = try FileHandle(forWritingTo: temp); defer { try? stream.close() }
        try stream.write(contentsOf: data); try stream.synchronize()
        guard rename(temp.path, directory.appendingPathComponent("transcript.json").path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
