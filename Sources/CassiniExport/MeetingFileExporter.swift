// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CryptoKit
import CassiniKit
import CassiniLibrary

public final class ExportArtifact: @unchecked Sendable {
    public let url: URL
    private let directory: URL
    init(directory: URL, filename: String) { self.directory = directory; url = directory.appendingPathComponent(filename) }
    deinit { try? FileManager.default.removeItem(at:directory) }
}

public enum MeetingFileExporter {
    public static func estimatedBytes(_ meeting: LibraryMeeting) throws -> Int64? {
        if meeting.state.origin == .received, let file = meeting.audioFiles.first {
            return (try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.int64Value
        }
        let inputs = try meeting.audioTracks.map { try PCMInput($0,ownership:OthersOwnership(events:meeting.captureEvents)) }
        let frames = inputs.map { $0.offsetFrames + $0.outputFrames }.max() ?? 0
        guard frames > 0 else { return nil }
        let choice = AudioEncodeChoice.choose(inputs.map(\.source))
        let bytes = Double(frames) / 48000 * Double(choice.bitrateBps) / 8
        guard bytes < Double(Int64.max) else { return nil }; return Int64(bytes)
    }
    public static func markdown(_ meeting: LibraryMeeting, timeZone: TimeZone,
                                locale: Locale = .current, language: CassiniLanguage = .system,
                                temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> ExportArtifact {
        let artifact = try stage(in:temporaryRoot,filename:"meeting.md")
        let data = Data(MeetingMarkdown.render(meeting,timeZone:timeZone,locale:locale,language:language).utf8)
        guard data.count <= 64 * 1024 * 1024,
              FileManager.default.createFile(atPath:artifact.url.path,contents:data,attributes:[.posixPermissions:0o600]) else { throw MeetingExportError.tooLarge }
        return artifact
    }
    /// `timeZone`: the Library device's zone, used only when names.py must choose a
    /// namePrefix from a capture start without a recorded offset or from the import time.
    public static func cassini(_ meeting: LibraryMeeting, assets: OpusAssets?,
                               temporaryRoot: URL = FileManager.default.temporaryDirectory,
                               timeZone: TimeZone = .current,
                               shouldCancel: () -> Bool = { false }) throws -> ExportArtifact {
        try cassini(meeting,assets:assets,temporaryRoot:temporaryRoot,timeZone:timeZone,shouldCancel:shouldCancel,afterRead:nil)
    }
    /// `afterRead` (tests): runs after each attempt has read the meeting, before its
    /// metadata is checked, with the attempt number.
    static func cassini(_ meeting: LibraryMeeting, assets: OpusAssets?, temporaryRoot: URL, timeZone: TimeZone,
                        shouldCancel: () -> Bool, afterRead: ((Int) throws -> Void)?) throws -> ExportArtifact {
        guard meeting.state.lifecycle == .saved else { throw MeetingExportError.invalidSource }
        let artifact = try stage(in:temporaryRoot,filename:"meeting.opus")
        let directory = artifact.url.deletingLastPathComponent()
        let audio: Data, digest: AudioDigest, original: CassiniFile?, choice: AudioEncodeChoice?
        var dateTag: String?, originalTitle: String?, importedTranscript: [String:Any]?
        if meeting.state.origin == .received {
            guard meeting.audioFiles.count == 1, let url = meeting.audioFiles.first else { throw MeetingExportError.invalidSource }
            try regular(url)
            audio = try Data(contentsOf:url,options:.mappedIfSafe)
            try budget(bytes:Double(audio.count) * 2 + Double(256 << 20),directory:directory)
            let file = try CassiniReader.read(audio)
            guard case .success(let actual)? = file.audioDigest else { throw MeetingExportError.invalidSource }
            digest = actual; original = file.state == .ok ? file : nil; choice = nil
            importedTranscript = LibraryImport.importedTranscript(file)
            // A plain Opus file (no manifest) is trusted on import too: its DATE and TITLE count.
            if file.state == .ok || file.state == .plainAudio {
                dateTag = file.tags?["DATE"]
                // Trimmed, blank skipped, as LibraryImport chooses the title.
                originalTitle = [file.manifest?.meeting.title,file.tags?["TITLE"]]
                    .compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }.first { !$0.isEmpty }
            }
        } else {
            let inputs = try meeting.audioTracks.map { try PCMInput($0,ownership:OthersOwnership(events:meeting.captureEvents)) }
            guard let assets else { throw MeetingExportError.invalidAssets }
            let selected = AudioEncodeChoice.choose(inputs.map(\.source))
            let bare = directory.appendingPathComponent("audio.opus")
            try encode(inputs:inputs,choice:selected,assets:assets,to:bare,shouldCancel:shouldCancel)
            audio = try Data(contentsOf:bare,options:.mappedIfSafe)
            digest = try OpusAudioDigest.compute(audio); original = nil; choice = selected
        }
        if shouldCancel() { throw CancellationError() }
        // D55.1: the namePrefix is saved before the first export (our own namespace checks it
        // was; another writer's copy keeps its own prefix).
        try? CodemyriadNamespace.persistNamePrefix(meeting,dateTag:dateTag,now:Date(),zone:timeZone)
        // #116 r3: the words, speakers, title, notes and namespace all come from one read of
        // the meeting, never the caller's snapshot (Export may have opened before a Write down
        // finished). Every change to the words bumps meeting.json's revision, and the namespace
        // checks that revision (under the folder lock for another writer's copy): if it moved
        // since this read, the meeting is read again.
        var attempt = 0
        let tags: Data, items: [LibraryTranscriptItem]
        // One scanner: its cache keeps unchanged files (original.opus) cheap across attempts.
        let scanner = LibraryScanner(root:meeting.folder.deletingLastPathComponent())
        while true {
            if shouldCancel() { throw CancellationError() }
            // An external file (opened, not in the Library) has no metadata to read again.
            let reread = LibraryScanner.isMeetingFolder(meeting.folder)
                ? scanner.meeting(at:meeting.folder) : meeting
            guard let current = reread, current.state.lifecycle == .saved else { throw MeetingExportError.invalidSource }
            let complete = current.state.transcript == .done
            let words = complete ? current.transcriptItems : []
            // D53.2: body and descriptor carry the run's language, or "und" when unknown.
            let language = TranscriptLanguage.written(complete ? (current.transcriptLanguage ?? original?.defaultTranscript?.load.transcript?.language) : nil)
            struct Body: Encodable { let language: String; let items: [LibraryTranscriptItem] }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            let body = try encoder.encode(Body(language:language,items:words))
            do {
                try afterRead?(attempt)
                let manifest = try self.manifest(current,digest:digest,original:original,choice:choice,dateTag:dateTag,originalTitle:originalTitle,
                                                 timeZone:timeZone,importedTranscript:importedTranscript,body:body,words:words,language:language)
                tags = try PortableMeetingTags.make(manifest:manifest,transcript:body,language:language,wordCount:words.count,shouldCancel:shouldCancel)
                items = words; break
            } catch is CodemyriadNamespace.MetadataChanged {
                attempt += 1
                guard attempt < 8 else { throw MeetingExportError.invalidSource }
            }
        }
        _ = try OpusStreamFile.rewrite(audio,tags:tags,to:artifact.url,shouldCancel:shouldCancel)
        let verified = try CassiniReader.read(contentsOf:artifact.url)
        guard verified.state == .ok, try verified.audioDigest?.get() == digest,
              verified.defaultTranscript?.load.transcript?.items.count == items.count else { throw MeetingExportError.invalidSource }
        try? FileManager.default.removeItem(at:directory.appendingPathComponent("audio.opus"))
        return artifact
    }
    private static func encode(inputs: [PCMInput], choice: AudioEncodeChoice, assets: OpusAssets,
                               to url: URL, shouldCancel: () -> Bool) throws {
        let frames = inputs.map { $0.offsetFrames + $0.outputFrames }.max() ?? 0
        guard frames > 0 else { throw MeetingExportError.invalidSource }
        try budget(frames:frames,bitrate:choice.bitrateBps,directory:url.deletingLastPathComponent())
        let encoder = try OpusEncoder(assets:assets,choice:choice)
        let writer = try OpusPacketWriter(url:url,head:OpusPacketWriter.monoHead(preSkip:encoder.preSkip),tags:PortableMeetingTags.packet())
        var limiter = PeakLimiter(), pending: [Float] = [], pendingAt = 0
        func emit(_ samples: [Float]) throws {
            pending.append(contentsOf:samples)
            while pending.count - pendingAt >= 960 {
                if shouldCancel() { throw CancellationError() }
                try writer.append(encoder.encode(Array(pending[pendingAt..<pendingAt + 960]))); pendingAt += 960
            }
            if pendingAt > 0 { pending.removeFirst(pendingAt); pendingAt = 0 }
        }
        var position: Int64 = 0
        while position < frames {
            if shouldCancel() { throw CancellationError() }
            var block = [Float](repeating:0,count:Int(min(960,frames - position)))
            for input in inputs { try input.add(to:&block,position:position) }
            try emit(limiter.feed(block)); position += Int64(block.count)
        }
        try emit(limiter.finish()); try emit([Float](repeating:0,count:encoder.preSkip))
        if !pending.isEmpty { try emit([Float](repeating:0,count:960 - pending.count)) }
        try writer.finish(sampleCount:Int(frames))
    }
    private static func manifest(_ meeting: LibraryMeeting, digest: AudioDigest, original file: CassiniFile?, choice: AudioEncodeChoice?,
                                 dateTag: String?, originalTitle: String?, timeZone: TimeZone,
                                 importedTranscript: [String:Any]?, body: Data, words: [LibraryTranscriptItem], language: String) throws -> JSON {
        let original = file?.manifest
        var extensions = original?.raw["x"] ?? .object([])
        var owned = extensions["gocassini.com"] ?? .object([])
        // D13, Q13: note objects in order, unknown members kept; absent means []. Another
        // writer's schema-1 copy (D55.1) takes the user's changes on Mac, with its revision and
        // the notes decided together under the folder lock; a Library meeting without one gets
        // our own copy (`make`), from the same read of meeting.json, and only from a real one.
        // A copy `merged` declines (an unknown schema or unusable revision), and any file opened
        // from outside the Library (nothing of it can change on Mac), stay unchanged.
        let originalNotes = extensions["gocassini.com"]?["notes"]
        let foreign = extensions[CodemyriadNamespace.key]
        var notes: JSON?, namespace: JSON?, mergedCopy = false
        if !LibraryScanner.isMeetingFolder(meeting.folder) {
            notes = originalNotes
        } else if let foreign, let merged = try CodemyriadNamespace.merged(foreign,with:meeting,originalNotes:originalNotes,importedTranscript:importedTranscript,
                                                                           body:SHA256.hash(data:body).map { String(format:"%02x",$0) }.joined(),
                                                                           bodyMatchesOriginal:bodyMatches(words:words,language:language,original:file),
                                                                           damaged:meeting.state.transcript == .damaged) {
            notes = merged.notes; namespace = merged.namespace; mergedCopy = true
        } else {
            let stored = try CodemyriadNamespace.current(meeting)
            let local = CodemyriadNamespace.localNotes(stored)
                ?? (meeting.notes.isEmpty ? nil : .array(meeting.notes.map { .object([("atMs",.number(String($0.atMs))),("text",.string($0.text))]) }))
            notes = CodemyriadNamespace.exportNotes(local:local,original:originalNotes).notes
            if foreign == nil, let stored {
                // A namePrefix that could not be saved would be chosen again by each export, so
                // one revision could carry different names (Coordinator, #116: an unwritable
                // folder fails the export). Metadata Mac may not rewrite is exempt.
                if !(stored["namePrefix"]?.string.map(LibraryNames.isPrefix) ?? false),
                   !meeting.metadataReadOnly, !meeting.issues.contains(.invalidMetadata) { throw MeetingExportError.libraryFolderNotWritable }
                namespace = try CodemyriadNamespace.make(meeting,stored:stored,dateTag:dateTag,originalTitle:originalTitle,now:Date(),zone:timeZone)
                    .map { try CodemyriadNamespace.marking($0,damaged:meeting.state.transcript == .damaged) }
            }
        }
        // The displayed title (MAPPING: meeting.title, then automaticTitle): for another
        // writer's copy, the one its namespace implies, so a cleared title matches it.
        let implied = mergedCopy ? [namespace?["meeting"]?["title"]?.string,namespace?["automaticTitle"]?.string]
            .compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }.first { !$0.isEmpty } : nil
        guard let title = implied ?? meeting.exportTitle ?? meeting.title, !title.isEmpty else { throw MeetingExportError.invalidSource }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let audio: JSON = .object([("container",.string("ogg")),("codec",.string("opus")),("sampleRate",.number("48000")),
            ("channels",.number(String(digest.channels))),("sampleCount",.number(String(digest.sampleCount))),("durationMs",.number(String(digest.durationMs)))])
        let integrity: JSON = .object([("matchPolicy",.string("exact-opus-audio-v1")),("opusAudioSha256",.string(digest.sha256)),
            ("sampleRate",.number("48000")),("channels",.number(String(digest.channels))),("sampleCount",.number(String(digest.sampleCount))),("durationMs",.number(String(digest.durationMs)))])
        var info: JSON = .object([("id",.string(original?.meeting.id ?? "mtg_" + digest.sha256)),("title",.string(title)),
            ("createdAtUtc",.string(iso.string(from:Date()))),("durationMs",.number(String(digest.durationMs)))])
        if meeting.state.origin == .own, let start = meeting.start {
            let local = ISO8601DateFormatter(); local.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; local.timeZone = .current
            info = try info.setting("recordedAtLocal",to:.string(local.string(from:start)))
        } else if let recorded = original?.meeting.recordedAtLocal {
            // A received meeting's start is an R6 display/sort value: it may be
            // the artifact's stamp or its import date. Neither is a recording
            // start. Keep only the verified original field, including its zone.
            info = try info.setting("recordedAtLocal",to:.string(recorded))
        }
        // Q2: one entry per speaker id the exported words use (none while they aren't exported).
        let used = Set(words.map(\.speaker))
        let speakers: JSON = .array(meeting.speakers.filter { used.contains($0.id) }.map { .object([("id",.string($0.id)),("label",.string($0.displayName))]) })
        var root: JSON = .object([("kind",.string("cassini-portable-meeting")),("version",.number("1")),("profile",.string("ogg-opus")),
            ("meeting",info),("audio",audio),("integrity",integrity),("speakers",speakers)])
        if let choice { root = try root.setting("audioEncode",to:JSONParser.parse(JSONEncoder().encode(choice))) }
        else if let recorded = original?.raw["audioEncode"] { root = try root.setting("audioEncode",to:recorded) }
        if meeting.state.origin == .own, meeting.audioTracks.contains(where:{ $0.frameCount != 0 && $0.startOffsetMs == nil }) {
            owned = try owned.setting("recovery",to:.object([("offsetsAssumedZero",.bool(true))]))
        }
        if notes != nil || owned.object != nil {
            owned = try owned.setting("notes",to:notes)
            extensions = try extensions.setting("gocassini.com",to:owned.object?.isEmpty == true ? nil : owned)
        }
        if let namespace { extensions = try extensions.setting(CodemyriadNamespace.key,to:namespace) }
        if extensions.object?.isEmpty != true { root = try root.setting("x",to:extensions) }
        return root
    }
    /// The exported words are the original file's: its only transcript, same words and language.
    private static func bodyMatches(words: [LibraryTranscriptItem], language: String, original: CassiniFile?) -> Bool {
        guard let original, original.transcripts.count <= 1 else { return original == nil && words.isEmpty }
        guard let body = original.defaultTranscript?.load.transcript else { return words.isEmpty && original.transcripts.isEmpty }
        // In the scanner's order: by start, ties in file order.
        let theirs = body.items.map { LibraryTranscriptItem(speaker:$0.speaker,startMs:Int64($0.startMs),endMs:Int64($0.endMs),text:$0.text) }
            .enumerated().sorted { $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs }.map(\.element)
        return theirs == words && TranscriptLanguage.written(body.language) == language
    }
    private static func regular(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw MeetingExportError.invalidSource }
    }
    private static func stage(in root: URL, filename: String) throws -> ExportArtifact {
        let directory = root.appendingPathComponent("CassiniExport-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return .init(directory:directory,filename:filename)
    }
    private static func budget(frames: Int64, bitrate: Int, directory: URL) throws {
        let estimate = Double(frames) / 48000 * Double(bitrate) / 8 * 3 + Double(256 << 20)
        try budget(bytes:estimate,directory:directory)
    }
    private static func budget(bytes estimate: Double, directory: URL) throws {
        let info = try FileManager.default.attributesOfFileSystem(forPath:directory.path)
        let free = (info[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
        let total = (info[.systemSize] as? NSNumber)?.doubleValue ?? 0
        let reserve = max(Double(1 << 30),total / 50)
        guard estimate < free - reserve else { throw POSIXError(.ENOSPC) }
    }
}
