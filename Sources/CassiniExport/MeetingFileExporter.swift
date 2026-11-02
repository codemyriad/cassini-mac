// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
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
                                locale: Locale = .current,
                                temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> ExportArtifact {
        let artifact = try stage(in:temporaryRoot,filename:"meeting.md")
        let data = Data(MeetingMarkdown.render(meeting,timeZone:timeZone,locale:locale).utf8)
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
        guard meeting.state.lifecycle == .saved else { throw MeetingExportError.invalidSource }
        let artifact = try stage(in:temporaryRoot,filename:"meeting.opus")
        let directory = artifact.url.deletingLastPathComponent()
        let audio: Data, digest: AudioDigest, original: CassiniFile?, choice: AudioEncodeChoice?
        var dateTag: String?, originalTitle: String?
        if meeting.state.origin == .received {
            guard meeting.audioFiles.count == 1, let url = meeting.audioFiles.first else { throw MeetingExportError.invalidSource }
            try regular(url)
            audio = try Data(contentsOf:url,options:.mappedIfSafe)
            try budget(bytes:Double(audio.count) * 2 + Double(256 << 20),directory:directory)
            let file = try CassiniReader.read(audio)
            guard case .success(let actual)? = file.audioDigest else { throw MeetingExportError.invalidSource }
            digest = actual; original = file.state == .ok ? file : nil; choice = nil
            if original != nil {
                dateTag = file.tags?["DATE"]
                originalTitle = [file.manifest?.meeting.title,file.tags?["TITLE"]].compactMap { $0 }.first { !$0.isEmpty }
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
        let complete = meeting.state.transcript == .done
        let items = complete ? meeting.transcriptItems : []
        // D53.2: body and descriptor carry the run's language, or "und" when unknown.
        let language = TranscriptLanguage.written(complete ? (meeting.transcriptLanguage ?? original?.defaultTranscript?.load.transcript?.language) : nil)
        struct Body: Encodable { let language: String; let items: [LibraryTranscriptItem] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let body = try encoder.encode(Body(language:language,items:items))
        let ours = try CodemyriadNamespace.make(meeting,dateTag:dateTag,originalTitle:originalTitle,now:Date(),zone:timeZone)
        let manifest = try self.manifest(meeting,digest:digest,original:original?.manifest,choice:choice,codemyriad:ours)
        let tags = try PortableMeetingTags.make(manifest:manifest,transcript:body,language:language,wordCount:items.count,shouldCancel:shouldCancel)
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
    private static func manifest(_ meeting: LibraryMeeting, digest: AudioDigest, original: Manifest?, choice: AudioEncodeChoice?, codemyriad: JSON? = nil) throws -> JSON {
        guard let title = meeting.exportTitle ?? meeting.title, !title.isEmpty else { throw MeetingExportError.invalidSource }
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
        let speakers: JSON = .array(meeting.speakers.map { .object([("id",.string($0.id)),("label",.string($0.displayName))]) })
        var root: JSON = .object([("kind",.string("cassini-portable-meeting")),("version",.number("1")),("profile",.string("ogg-opus")),
            ("meeting",info),("audio",audio),("integrity",integrity),("speakers",speakers)])
        if let choice { root = try root.setting("audioEncode",to:JSONParser.parse(JSONEncoder().encode(choice))) }
        else if let recorded = original?.raw["audioEncode"] { root = try root.setting("audioEncode",to:recorded) }
        var extensions = original?.raw["x"] ?? .object([])
        var owned = extensions["gocassini.com"] ?? .object([])
        if meeting.state.origin == .own, meeting.audioTracks.contains(where:{ $0.frameCount != 0 && $0.startOffsetMs == nil }) {
            owned = try owned.setting("recovery",to:.object([("offsetsAssumedZero",.bool(true))]))
        }
        // D13, Q13: meeting.json's own note objects in order, unknown members kept; absent means [].
        let notes: JSON? = meeting.notes.isEmpty ? nil : CodemyriadNamespace.rawNotes(meeting)
            ?? .array(meeting.notes.map { .object([("atMs",.number(String($0.atMs))),("text",.string($0.text))]) })
        if notes != nil || owned.object != nil {
            owned = try owned.setting("notes",to:notes)
            extensions = try extensions.setting("gocassini.com",to:owned.object?.isEmpty == true ? nil : owned)
        }
        // R65 (D55): our own namespace. A file that already carries one (another app or
        // schema) keeps it unchanged: Mac never downgrades or rewrites it.
        if extensions[CodemyriadNamespace.key] == nil, let codemyriad {
            extensions = try extensions.setting(CodemyriadNamespace.key,to:codemyriad)
        }
        if extensions.object?.isEmpty != true { root = try root.setting("x",to:extensions) }
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
