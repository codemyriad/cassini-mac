// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniLibrary
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
            try setStatus(directory: directory, id: meeting.id, status: "running")
            let received = meeting.state.origin == .received
            struct Track {
                let audio: SegmentedAudio; let speaker: TranscriptSpeaker; let offset: Int64
                /// Speech segments clipped to the half-open ranges this source owns.
                let segments: [SpeechSegment]
            }
            var tracks: [Track] = []
            let sources: [(URL, String, String, Double?, String?, Double?)]
            if received { sources = [(meeting.audioFiles[0], "original", "original", 0, nil, nil)] }
            else {
                // The Library scanner already isolates damaged tracks and
                // safely salvages unsupported/missing manifests. Reuse those
                // exact sources instead of reopening every raw manifest path.
                sources = meeting.audioTracks.compactMap { track in
                    guard track.frameCount != 0 else { return nil }
                    let filenameID = String(track.url.deletingPathExtension().lastPathComponent.dropFirst("track-".count))
                    return (track.url,track.sourceID ?? filenameID,track.sourceKind ?? "media",track.startOffsetMs,track.sourceTrackID,track.endOffsetMs)
                }
            }
            // D52 M1: one source becomes one speaker only while its spans are disjoint.
            let lanes = SourceSpanLanes.assign(sources.compactMap { url, id, kind, offset, sourceTrackID, end in
                let base = TranscriptSpeaker.fromTrack(id:id,kind:kind,sourceTrackID:sourceTrackID,received:received,me:me,others:others).id
                guard base.hasPrefix("track-"), !received else { return nil }
                return .init(id:id,base:base,startMs:offset,endMs:offset == nil ? nil : end)
            })
            let separated = lanes.values.contains { $0.contains(":overlap:") }
            let ownership = received ? nil : OthersOwnership(events:meeting.captureEvents)
            for (url, id, kind, offset, sourceTrackID, _) in sources {
                if offset == nil { fputs("Cassini transcription: unknownStartOffset; using 0 for word times\n", stderr) }
                var speaker = TranscriptSpeaker.fromTrack(id: id, kind: kind, sourceTrackID:sourceTrackID, received: received, me: me, others: others)
                if let lane = lanes[id] { speaker = .init(id:lane,name:speaker.name) }
                let audio = try SegmentedAudio(url: url, detector: detector)
                var segments = audio.segments
                // D49/D33 seams: audio outside this source's ownership is not recognized.
                if let ownership, let offset {
                    let owned = ownership.owned(kind:kind,startMs:offset,endMs:offset + Double(audio.sampleCount)/16)
                    segments = segments.flatMap { segment in
                        owned.compactMap { range -> SpeechSegment? in
                            // D52.2 presence grid: [a,b) ms covers samples [ceil(16a-1e-6), ceil(16b-1e-6)).
                            let a = max(segment.startSample,Int(((range.0-offset)*16 - 1e-6).rounded(.up)))
                            let b = min(segment.endSample,Int(((range.1-offset)*16 - 1e-6).rounded(.up)))
                            return b > a ? .init(startSample:a,endSample:b,reason:segment.reason) : nil
                        }
                    }
                }
                tracks.append(.init(audio: audio, speaker: speaker, offset: Int64(floor(offset ?? 0)), segments: segments))
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
            func publish(status: String) throws {
                let ordered = progress.published(items,complete:status == "done")
                struct Body: Encodable { let language: String; let items: [LibraryTranscriptItem] }
                let data = try JSONEncoder().encode(Body(language: language, items: ordered))
                guard data.count <= 64 * 1024 * 1024 else { throw TranscriptionFailure.runtime("transcript size limit") }
                try atomicTranscript(data, directory: directory)
                let factor = processed > 0 ? elapsed / processed : initialETA
                let eta = Int64(ceil(max(0, remaining) * factor / 60))
                try writer.transaction { metadata in
                    metadata["transcript"] = ["status":status, "reference":reference, "model":model]
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
                        // D52.3d: a stored fact, replaced by each completed attempt; unknown fields survive.
                        var details = metadata["recordingDetails"] as? [String:Any] ?? [:]
                        var writing = details["writingDown"] as? [String:Any] ?? [:]
                        if separated { writing["sourceSpansSeparated"] = true } else { writing.removeValue(forKey:"sourceSpansSeparated") }
                        if writing.isEmpty { details.removeValue(forKey:"writingDown") } else { details["writingDown"] = writing }
                        if details.isEmpty { metadata.removeValue(forKey:"recordingDetails") } else { metadata["recordingDetails"] = details }
                    }
                }
            }
            try publish(status: "running")
            for (index, track) in tracks.enumerated() {
                for segment in track.segments {
                    let began = ProcessInfo.processInfo.systemUptime, samples = try track.audio.samples(segment)
                    let result = try recognize(samples)
                    if language == "auto" { language = result.language }
                    let start = track.offset + Int64(segment.startSample * 1000 / 16000)
                    for word in result.words ?? [] {
                        guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start, word.end <= Double(samples.count) / 16000 + 1 else { throw TranscriptionFailure.runtime("invalid recognizer word timestamp") }
                        let a = start + Int64((word.start * 1000).rounded(.toNearestOrEven)), b = start + Int64((word.end * 1000).rounded(.toNearestOrEven))
                        items.append(.init(word: .init(speaker: track.speaker.id, startMs: a, endMs: b, text: word.word), track: index, ordinal: items.count))
                    }
                    let speech = Double(samples.count) / 16000
                    processed += speech; remaining -= speech; elapsed += max(0, ProcessInfo.processInfo.systemUptime - began)
                    progress.advance(track:index,to:track.offset + Int64(segment.endSample * 1000 / 16000))
                    try publish(status: "running")
                }
                progress.finish(track:index)
                try publish(status:"running")
            }
            try publish(status: "done")
        } catch { try? setStatus(directory: directory, id: meeting.id, status: "failed"); throw error }
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
