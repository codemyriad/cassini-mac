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
        // A trusted original's own tags (DATE, ARTIST, …): a Cassini file's, or a plain Opus file's.
        var tagSource: CassiniFile?
        if meeting.state.origin == .received {
            guard meeting.audioFiles.count == 1, let url = meeting.audioFiles.first else { throw MeetingExportError.invalidSource }
            try regular(url)
            audio = try Data(contentsOf:url,options:.mappedIfSafe)
            try budget(bytes:Double(audio.count) * 2 + Double(256 << 20),directory:directory)
            let file = try CassiniReader.read(audio)
            guard case .success(let actual)? = file.audioDigest else { throw MeetingExportError.invalidSource }
            digest = actual; original = file.state == .ok ? file : nil; choice = nil
            tagSource = [.ok,.plainAudio].contains(file.state) ? file : nil
            importedTranscript = LibraryImport.importedTranscript(file)
            // #116 r4: a trusted file opened from outside the Library that carries our namespace
            // goes out byte-for-byte (nothing of it can change on Mac, and a rebuild could drop
            // its other transcripts under the same revision), once its namespace is one this app
            // can carry (D65).
            if !LibraryScanner.isMeetingFolder(meeting.folder), file.state == .ok, let namespace = file.manifest?.raw["x"]?[CodemyriadNamespace.key] {
                _ = try CodemyriadNamespace.validated(namespace)
                guard FileManager.default.createFile(atPath:artifact.url.path,contents:audio,attributes:[.posixPermissions:0o600]) else { throw MeetingExportError.invalidSource }
                let copied = try CassiniReader.read(contentsOf:artifact.url)
                guard copied.state == .ok, try copied.audioDigest?.get() == actual else { throw MeetingExportError.invalidSource }
                return artifact
            }
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
        var carried = 0
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
                // #122 review: a received file's transcripts go out byte for byte while Mac hasn't
                // written it down; Mac's own words, once it has, become the default and every
                // original transcript stays beside them, unchanged. Nothing Mac doesn't model
                // (an item's attribution facts, a second transcript) is rebuilt or dropped.
                // Mac's words join the file only once its own Write down finished; while it is
                // queued, running or failed, Mac has no words and the originals go out as they are.
                let stored = try CodemyriadNamespace.current(current)
                let writtenOnMac = original != nil && CodemyriadNamespace.transcribedOnMac(stored,importedTranscript:importedTranscript)
                let mine = original == nil || (writtenOnMac && complete)
                let set = try PortableMeetingTags.transcripts(own:mine ? (body,language,words.count) : nil,carried:original,shouldCancel:shouldCancel)
                let manifest = try self.manifest(current,digest:digest,original:original,choice:choice,dateTag:dateTag,originalTitle:originalTitle,
                                                 timeZone:timeZone,importedTranscript:importedTranscript,transcripts:set,carriedOnly:!mine,
                                                 damaged:(original == nil || writtenOnMac) && current.state.transcript == .damaged,stored:stored,words:words)
                tags = try PortableMeetingTags.make(manifest:manifest,transcripts:set,
                                                    carriedTags:tagSource.map { PortableMeetingTags.carriedTags($0,besides:set) } ?? [],shouldCancel:shouldCancel)
                items = mine ? words : []; carried = set.entries.count; break
            } catch is CodemyriadNamespace.MetadataChanged {
                attempt += 1
                guard attempt < 8 else { throw MeetingExportError.invalidSource }
            }
        }
        _ = try OpusStreamFile.rewrite(audio,tags:tags,to:artifact.url,shouldCancel:shouldCancel)
        let verified = try CassiniReader.read(contentsOf:artifact.url)
        guard verified.state == .ok, try verified.audioDigest?.get() == digest, verified.transcripts.count == carried,
              items.isEmpty || verified.defaultTranscript?.load.transcript?.items.count == items.count else { throw MeetingExportError.invalidSource }
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
                                 importedTranscript: [String:Any]?, transcripts: PortableTranscripts, carriedOnly: Bool,
                                 damaged: Bool, stored: JSON?, words: [LibraryTranscriptItem]) throws -> JSON {
        // `damaged`: Mac's own words (a recording's, or a received file's Write down) were read as
        // damaged; a received file's originals go out as they came, whatever Mac read of them.
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
        // `stored` is meeting.json as this attempt read it (checked against the snapshot), for
        // every path: the notes, our own namespace, the untitled title and the speaker names.
        var notes: JSON?, namespace: JSON?, mergedCopy = false, own = false
        // D65: a namespace schema this app doesn't know is refused, never shipped next to
        // content its revision doesn't describe (also for a file opened from outside).
        if let foreign { _ = try CodemyriadNamespace.validated(foreign) }
        if !LibraryScanner.isMeetingFolder(meeting.folder) {
            notes = originalNotes
        } else if let foreign {
            let merged = try CodemyriadNamespace.merged(foreign,with:meeting,originalNotes:originalNotes,importedTranscript:importedTranscript,
                                                        body:transcripts.digest,bodyMatchesOriginal:carriedOnly,damaged:damaged)
            notes = merged.notes; namespace = merged.namespace; mergedCopy = true
        } else {
            let local = CodemyriadNamespace.localNotes(stored)
                ?? (meeting.notes.isEmpty ? nil : .array(meeting.notes.map { .object([("atMs",.number(String($0.atMs))),("text",.string($0.text))]) }))
            notes = CodemyriadNamespace.exportNotes(local:local,original:originalNotes).notes
            // Metadata Mac may not rewrite (unsupported or invalid) can't keep the baseline that
            // pins a revision to one content (words read from transcript.json, a namePrefix or
            // untitled title chosen per export), so it gets no namespace of ours (D65).
            // A namePrefix that could not be saved would be chosen again by each export, so one
            // revision could carry different names: an app-owned folder that can't be written
            // refuses (D65), and a read-only Library gets no namespace of ours instead. The same
            // for the untitled fallback (Q6b).
            let unsaved = stored.map { !($0["namePrefix"]?.string.map(LibraryNames.isPrefix) ?? false) || (meeting.titleIsUntitled && CodemyriadNamespace.untitled($0) == nil) } ?? false
            if unsaved, foreign == nil, !meeting.metadataReadOnly, !meeting.issues.contains(.invalidMetadata), CodemyriadNamespace.libraryWritable(meeting) {
                throw MeetingExportError.libraryFolderNotWritable
            }
            if foreign == nil, !unsaved, let stored, !meeting.metadataReadOnly, !meeting.issues.contains(.invalidMetadata) {
                namespace = try CodemyriadNamespace.make(meeting,stored:stored,dateTag:dateTag,originalTitle:originalTitle,now:Date(),zone:timeZone)
                    .map { try CodemyriadNamespace.marking($0,damaged:damaged) }
                own = namespace != nil
            }
        }
        // The displayed title (MAPPING: meeting.title, then automaticTitle): for another
        // writer's copy, the one its namespace implies, so a cleared title matches it.
        let implied = mergedCopy ? [namespace?["meeting"]?["title"]?.string,namespace?["automaticTitle"]?.string]
            .compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }.first { !$0.isEmpty } : nil
        // D65 (Q6b): without a title, the untitled fallback in the language of the first export,
        // so a later language change never changes the title under the same revision.
        let untitled = meeting.titleIsUntitled ? CodemyriadNamespace.untitled(stored) : nil
        guard let title = implied ?? untitled ?? meeting.exportTitle ?? meeting.title, !title.isEmpty else { throw MeetingExportError.invalidSource }
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
        let projected = meeting.speakers.filter { used.contains($0.id) }
        var speakers: JSON = .array(projected.map { .object([("id",.string($0.id)),("label",.string($0.displayName))]) })
        // #122 review (MAPPING §6): a received file's speaker entries describe the transcripts it
        // carries, so they stay with their unknown members; Mac's name for one replaces its label,
        // and the speakers of Mac's own words follow.
        if let theirs = original?.raw["speakers"]?.array {
            var merged = theirs
            // A name the user gave on Mac (meeting.json), and Mac's label for a speaker of
            // Mac's own words, replace the original label; nothing else changes.
            let named = Dictionary((stored?["speakers"]?.array ?? []).compactMap { entry -> (String,String)? in
                guard entry["provenance"]?.string == "user", let id = entry["id"]?.string, let name = entry["name"]?.string else { return nil }
                return (id,name)
            },uniquingKeysWith:{ first,_ in first })
            // A name the user cleared on Mac (#122 r3): the speaker reads as unnamed, labelled as
            // the catalog's unnamed speaker numbered by its place in this list, as the namespace says.
            let cleared = Set((stored?["speakers"]?.array ?? []).compactMap { entry -> String? in
                entry["nameCleared"] == .bool(true) && entry["name"]?.string == nil ? entry["id"]?.string : nil
            })
            for (index,entry) in merged.enumerated() {
                guard let id = entry["id"]?.string else { continue }
                let unnamed = cleared.contains(id) ? LibraryLocalization.shared.text("common.speaker.unnamed",["n":String(index + 1)]) : nil
                let label = named[id] ?? unnamed ?? (carriedOnly ? nil : projected.first { $0.id == id }?.displayName)
                guard let label, entry["label"]?.string != label else { continue }
                merged[index] = try entry.setting("label",to:.string(label))
            }
            // The speakers of Mac's own words follow; carried words keep the original list.
            if !carriedOnly {
                let listed = Set(theirs.compactMap { $0["id"]?.string })
                merged += projected.filter { !listed.contains($0.id) }.map { .object([("id",.string($0.id)),("label",.string($0.displayName))]) }
            }
            speakers = .array(merged)
        }
        // The original meeting's members Mac doesn't write stay (Mac's own facts win).
        for (name,value) in original?.raw["meeting"]?.object ?? [] where info[name] == nil && name != "recordedAtLocal" {
            info = try info.setting(name,to:value)
        }
        var root: JSON = .object([("kind",.string("cassini-portable-meeting")),("version",.number("1")),("profile",.string("ogg-opus")),
            ("meeting",info),("audio",audio),("integrity",integrity),("speakers",speakers)])
        // ... and so do its top-level members Mac doesn't write (provenance, attachments, any
        // member a later format adds). The transcripts are carried separately, payloads and all.
        // Provenance describes the default transcript's words: once Mac's words are the default,
        // the original's no longer applies.
        for (name,value) in original?.raw.object ?? [] where root[name] == nil && !["transcripts","x","audioEncode"].contains(name) && (carriedOnly || name != "provenance") {
            root = try root.setting(name,to:value)
        }
        // The same audio: its members Mac doesn't write stay beside the measured facts.
        if let theirs = original?.raw["audio"]?.object {
            var merged = root["audio"]!
            for (name,value) in theirs where merged[name] == nil { merged = try merged.setting(name,to:value) }
            root = try root.setting("audio",to:merged)
        }
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
        if own, var namespace {
            // #116 r4: the revision this content takes. The digest covers everything the file
            // carries except the export stamp and the revision itself.
            var content = try root.setting("meeting",to:root["meeting"]!.setting("createdAtUtc",to:nil))
            content = try content.setting("x",to:extensions.setting(CodemyriadNamespace.key,to:namespace.setting("revision",to:nil)))
            var data = try content.encoded(); data.append(0); data.append(Data(transcripts.digest.utf8))
            do {
                let revision = try CodemyriadNamespace.ownRevision(meeting,digest:SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined())
                namespace = try namespace.setting("revision",to:.number(String(revision)))
                root = try root.setting("x",to:extensions.setting(CodemyriadNamespace.key,to:namespace))
            } catch MeetingExportError.libraryFolderNotWritable where !CodemyriadNamespace.libraryWritable(meeting) {
                // A read-only Library: no baseline, so no namespace of ours.
                let without = try extensions.setting(CodemyriadNamespace.key,to:nil)
                root = try root.setting("x",to:without.object?.isEmpty == false ? without : nil)
            }
        }
        return root
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
