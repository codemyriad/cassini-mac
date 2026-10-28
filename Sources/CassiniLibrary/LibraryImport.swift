// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin
import CassiniKit

/// R1.4: original bytes are private and complete before meeting.json commits the
/// import. A full-file hash identifies repeats, regardless of source filename.
public enum LibraryImport {
    public static func copy(_ source: URL, into root: URL, shouldCancel: () -> Bool = { false }) throws -> LibraryMeeting {
        let (input, identity) = try openRegular(source); defer { close(input) }
        guard identity.size > 0, identity.size <= Int64(UInt32.max) else { throw POSIXError(.EFBIG) }
        let read = FileHandle(fileDescriptor:input,closeOnDealloc:false)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let rootFD = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw POSIXError(.ENOENT) }; defer { close(rootFD) }
        while flock(rootFD,LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
            if shouldCancel() { throw CancellationError() }
            Thread.sleep(forTimeInterval:0.02)
        }
        defer { flock(rootFD,LOCK_UN) }
        let id = UUID(), folder = root.appendingPathComponent("Received-" + id.uuidString.lowercased())
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at:folder) } }
        let original = folder.appendingPathComponent("original.opus")
        let output = open(original.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard output >= 0 else { throw POSIXError(.EIO) }
        let write = FileHandle(fileDescriptor:output,closeOnDealloc:true); defer { try? write.close() }
        var hash = SHA256(), copied: Int64 = 0
        while let data = try read.read(upToCount:1024 * 1024), !data.isEmpty {
            if shouldCancel() { throw CancellationError() }
            copied += Int64(data.count); guard copied <= identity.size else { throw POSIXError(.EINVAL) }
            hash.update(data:data); try write.write(contentsOf:data)
        }
        var after = stat()
        guard copied == identity.size, fstat(input,&after) == 0, FileKey(after) == identity else { throw POSIXError(.EINVAL) }
        try write.synchronize()
        let digest = hash.finalize().map { String(format:"%02x",$0) }.joined()
        let data = try Data(contentsOf:original,options:.mappedIfSafe)
        let file = try CassiniReader.read(data)
        guard case .success? = file.audioDigest else { throw MetadataError.invalid }
        let scanner = LibraryScanner(root:root)
        if let duplicate = try scanner.scan().meetings.first(where: { $0.received?.sha256 == digest }) { return duplicate }
        if shouldCancel() { throw CancellationError() }
        let trusted = [.ok,.plainAudio].contains(file.state)
        let selected = trusted ? file.defaultTranscript : nil
        let timed = file.transcripts.filter { $0.entry.format == "cassini.words.v1" }
        let emptyTimed = trusted && !timed.isEmpty && timed.allSatisfy { $0.load.transcript?.items.isEmpty == true }
        let importedNotes: [[String:Any]] = (trusted ? file.manifest?.raw["x"]?["gocassini.com"]?["notes"]?.array : nil)?.compactMap { note in
            guard let time = note["atMs"]?.int, time >= 0, time <= AppMetadata.safe,
                  let text = note["text"]?.string, text.unicodeScalars.count <= 100000 else { return nil }
            return ["atMs":time,"text":text]
        } ?? []
        let title = [trusted ? file.manifest?.meeting.title : nil,trusted ? file.tags?["TITLE"] : nil,source.deletingPathExtension().lastPathComponent]
            .compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }.first { !$0.isEmpty }
        if shouldCancel() { throw CancellationError() }
        try MeetingMetadataWriter(directory:folder,id:id).transaction { metadata in
            var received: [String:Any] = ["originalName":"original.opus","sha256":digest,"importedAtMs":Int64(Date().timeIntervalSince1970 * 1000)]
            let parent = String(String.UnicodeScalarView(source.deletingLastPathComponent().lastPathComponent.unicodeScalars.prefix(255)))
            if safeBasename(parent) { received["originalFolderName"] = parent }
            metadata["received"] = received
            metadata["notes"] = importedNotes
            if let title { metadata["title"] = String(String.UnicodeScalarView(title.unicodeScalars.prefix(500))) }
            if emptyTimed {
                // D12: a valid empty word-timed body is ready to write down.
                metadata["transcript"] = ["status":"none","reference":NSNull()]
            } else if selected?.load.transcript != nil {
                metadata["transcript"] = ["status":"done","reference":["kind":"embedded","file":"original.opus","transcriptId":selected!.entry.id]]
            } else if !trusted || selected != nil {
                metadata["transcript"] = ["status":"damaged","reference":NSNull()]
            }
        }
        guard let meeting = try scanner.scan().meetings.first(where: { $0.id == id }) else { throw POSIXError(.EINVAL) }
        committed = true; return meeting
    }
}
