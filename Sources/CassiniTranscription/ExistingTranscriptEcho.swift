// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniLibrary

/// D38.6: a resumable, model-free pass over completed, app-owned transcripts.
/// The marker is a private maintenance sidecar, not meeting/session provenance.
public enum ExistingTranscriptEcho {
    public static let markerName = ".cassini-echo-v1.json"
    public enum Outcome: Equatable, Sendable { case classified(Int), alreadyComplete, ineligible, changed }
    private struct FileState: Equatable {
        let device: Int32; let inode: UInt64; let size: Int64
        let modified: Int64; let modifiedNs: Int64; let changed: Int64; let changedNs: Int64
        init(_ url: URL) throws {
            var value = stat()
            guard lstat(url.path,&value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw TranscriptionFailure.invalidMeeting }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNs = Int64(value.st_mtimespec.tv_nsec)
            changed = Int64(value.st_ctimespec.tv_sec); changedNs = Int64(value.st_ctimespec.tv_nsec)
        }
    }
    private static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TranscriptionFailure.invalidMeeting }
        let file = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw TranscriptionFailure.invalidMeeting }
        let data = try file.read(upToCount:limit+1) ?? Data()
        guard data.count == info.st_size, data.count <= limit else { throw TranscriptionFailure.invalidMeeting }; return data
    }
    private static func metadata(_ folder: URL) throws -> Data? {
        let url = folder.appendingPathComponent("meeting.json")
        var info = stat()
        if lstat(url.path,&info) != 0, errno == ENOENT { return nil }
        return try read(url,limit:1_048_576)
    }
    private static func completedHash(_ folder: URL) -> String? {
        struct Marker: Decodable { let version: Int; let transcriptSHA256: String }
        guard let data = try? read(folder.appendingPathComponent(markerName),limit:4096),
              let marker = try? JSONDecoder().decode(Marker.self,from:data), marker.version == 1,
              marker.transcriptSHA256.count == 64, marker.transcriptSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return marker.transcriptSHA256
    }
    private static func temporary(_ data: Data, in folder: URL) throws -> URL {
        let path = folder.appendingPathComponent(".echo-"+UUID().uuidString+".tmp")
        let fd = open(path.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw TranscriptionFailure.invalidMeeting }
        let file = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        do { try file.write(contentsOf:data); try file.synchronize(); try file.close(); return path }
        catch { try? file.close(); try? FileManager.default.removeItem(at:path); throw error }
    }
    private static func marker(_ body: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject:["version":1,"transcriptSHA256":SHA256.hash(data:body).map { String(format:"%02x",$0) }.joined()],options:[.sortedKeys])
    }
    public static func markCompleted(directory: URL) throws {
        let body = try read(directory.appendingPathComponent("transcript.json"),limit:64*1024*1024)
        let temp = try temporary(marker(body),in:directory); defer { try? FileManager.default.removeItem(at:temp) }
        let fd = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TranscriptionFailure.invalidMeeting }; defer { close(fd) }
        guard flock(fd,LOCK_EX) == 0 else { throw TranscriptionFailure.invalidMeeting }; defer { flock(fd,LOCK_UN) }
        guard rename(temp.path,directory.appendingPathComponent(markerName).path) == 0 else { throw TranscriptionFailure.invalidMeeting }
        if fsync(fd) != 0 && errno != EINVAL { throw TranscriptionFailure.invalidMeeting }
    }
    public static func candidate(_ meeting: LibraryMeeting) -> Bool {
        meeting.state.origin == .own && meeting.state.lifecycle == .saved && meeting.state.transcript == .done &&
        !meeting.metadataReadOnly && !meeting.transcriptItems.isEmpty &&
        meeting.issues.allSatisfy { $0 == .unknownStartOffset } &&
        meeting.audioTracks.contains { MicrophoneEcho.microphoneKinds.contains($0.sourceKind ?? "") } &&
        meeting.audioTracks.contains { MicrophoneEcho.comparisonKinds.contains($0.sourceKind ?? "") }
    }
    /// `checkpoint` cancels decoding/measurement when recording starts. `commit`
    /// serializes the final short rename with capture admission in the app.
    public static func run(directory inputDirectory: URL, checkpoint: () throws -> Void = {},
                           commit: (() throws -> Void) throws -> Void = { try $0() }) throws -> Outcome {
        try checkpoint()
        var info = stat()
        guard lstat(inputDirectory.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let resolved = realpath(inputDirectory.path,nil) else { return .ineligible }
        let directory = URL(fileURLWithPath:String(cString:resolved),isDirectory:true); free(resolved)
        let lock = open(directory.appendingPathComponent(".transcription.lock").path,O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,0o600)
        guard lock >= 0 else { throw TranscriptionFailure.invalidMeeting }; defer { close(lock) }
        guard fstat(lock,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .ineligible }
        guard flock(lock,LOCK_EX | LOCK_NB) == 0 else { return .changed }; defer { flock(lock,LOCK_UN) }
        // Remove only our abandoned atomic-write files, under the same lease
        // used by inference and maintenance. SIGKILL cannot strand big drafts.
        for url in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] {
            let name = url.lastPathComponent
            guard name.hasPrefix(".echo-"), name.hasSuffix(".tmp"), UUID(uuidString:String(name.dropFirst(6).dropLast(4))) != nil else { continue }
            var value = stat()
            if lstat(url.path,&value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(), value.st_nlink == 1 { _ = unlink(url.path) }
        }
        let markerURL = directory.appendingPathComponent(markerName)
        if lstat(markerURL.path,&info) == 0 {
            guard let expected = completedHash(directory) else { return .ineligible }
            let current = try read(directory.appendingPathComponent("transcript.json"),limit:64*1024*1024)
            if SHA256.hash(data:current).map({ String(format:"%02x",$0) }).joined() == expected { return .alreadyComplete }
            // A crash may persist the marker but not the transcript rename.
            // Hash binding resumes that interrupted transaction safely.
        } else if errno != ENOENT { return .ineligible }
        let scanner = LibraryScanner(root:directory.deletingLastPathComponent())
        guard let meeting = try scanner.meeting(at:directory), candidate(meeting) else { return .ineligible }
        try checkpoint()
        let metadataBefore = try metadata(directory)
        let transcript = directory.appendingPathComponent("transcript.json")
        let body = try read(transcript,limit:64*1024*1024)
        guard var document = try JSONSerialization.jsonObject(with:body) as? [String:Any],
              var items = document["items"] as? [[String:Any]], items.count == meeting.transcriptItems.count else { return .ineligible }
        let audioBefore = try meeting.audioTracks.map { try FileState($0.url) }
        let sessionBefore = try read(directory.appendingPathComponent("session.json"),limit:1_048_576)
        var flagged = 0
        if !items.contains(where:{ ($0["echo"] as? Bool) == true }) {
            // Mono float scratch is bounded to one meeting; preserve room for
            // capture rather than filling the temporary volume on an upgrade.
            let estimated = audioBefore.reduce(0.0) { $0 + Double($1.size)*2 }
            let free = (try FileManager.default.attributesOfFileSystem(forPath:FileManager.default.temporaryDirectory.path)[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
            guard free > estimated + Double(1 << 30) else { return .ineligible }
            if meeting.audioTracks.contains(where:{ $0.startOffsetMs == nil }) { fputs("Cassini echo maintenance: unknownStartOffset; using 0 for audio levels\n",stderr) }
            struct Track { let audio: SegmentedAudio; let offset: Int64; let speaker: String; let kind: String }
            let tracks = try meeting.audioTracks.map { track -> Track in
                try checkpoint()
                let id = track.sourceID ?? String(track.url.deletingPathExtension().lastPathComponent.dropFirst("track-".count))
                return Track(audio:try SegmentedAudio(url:track.url,detector:nil,checkpoint:checkpoint),offset:Int64(floor(track.startOffsetMs ?? 0)),
                             speaker:TranscriptSpeaker.fromTrack(id:id,kind:track.sourceKind ?? "",sourceTrackID:track.sourceTrackID).id,kind:track.sourceKind ?? "")
            }
            let microphones = Set(tracks.indices.filter { MicrophoneEcho.microphoneKinds.contains(tracks[$0].kind) })
            let others = Set(tracks.indices.filter { MicrophoneEcho.comparisonKinds.contains(tracks[$0].kind) })
            var words: [MicrophoneEcho.Word] = []
            for item in items {
                try checkpoint()
                guard let speaker = item["speaker"] as? String, let start = (item["startMs"] as? NSNumber)?.int64Value,
                      let end = (item["endMs"] as? NSNumber)?.int64Value, let text = item["text"] as? String else { return .ineligible }
                let matches = tracks.indices.filter {
                    let track = tracks[$0]
                    return track.speaker == speaker && start >= track.offset && Double(start-track.offset) < Double(track.audio.sampleCount)/16
                }
                // A saved speaker can cover several physical spans. Never
                // guess a source when spans overlap or chronology is absent.
                let index = matches.count == 1 ? matches[0] : -1
                let level = index < 0 ? nil : try tracks[index].audio.rmsDbfs(from:start,to:end,offsetMs:tracks[index].offset)
                words.append(.init(track:index,startMs:start,endMs:end,text:text,rmsDbfs:level))
            }
            let flags = try MicrophoneEcho.flags(words,microphones:microphones,others:others,checkpoint:checkpoint) { index in
                try checkpoint()
                guard let level = words[index].rmsDbfs else { return false }
                for other in others.sorted() {
                    try checkpoint()
                    if let measured = try tracks[other].audio.rmsDbfs(from:max(0,words[index].startMs-600),to:words[index].endMs,offsetMs:tracks[other].offset), level <= measured-6 { return true }
                }
                return false
            }
            for index in items.indices where flags[index] { items[index]["echo"] = true; flagged += 1 }
            document["items"] = items
        }
        try checkpoint()
        let output = flagged == 0 ? body : try JSONSerialization.data(withJSONObject:document,options:[.sortedKeys])
        guard output.count <= 64*1024*1024 else { return .ineligible }
        let replacement = flagged == 0 ? nil : try temporary(output,in:directory)
        defer { if let replacement { try? FileManager.default.removeItem(at:replacement) } }
        let stamp = try temporary(marker(output),in:directory)
        defer { try? FileManager.default.removeItem(at:stamp) }
        let folder = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw TranscriptionFailure.invalidMeeting }; defer { close(folder) }
        guard flock(folder,LOCK_EX) == 0 else { throw TranscriptionFailure.invalidMeeting }; defer { flock(folder,LOCK_UN) }
        guard try metadata(directory) == metadataBefore, try read(transcript,limit:64*1024*1024) == body,
              try read(directory.appendingPathComponent("session.json"),limit:1_048_576) == sessionBefore,
              try meeting.audioTracks.map({ try FileState($0.url) }) == audioBefore else { return .changed }
        try checkpoint()
        try commit {
            if let replacement, rename(replacement.path,transcript.path) != 0 { throw TranscriptionFailure.invalidMeeting }
            guard rename(stamp.path,directory.appendingPathComponent(markerName).path) == 0 else { throw TranscriptionFailure.invalidMeeting }
            if fsync(folder) != 0 && errno != EINVAL { throw TranscriptionFailure.invalidMeeting }
        }
        return .classified(flagged)
    }
}
