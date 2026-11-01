// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniKit

/// D52.3a minimal Recording details: the source rows, gaps and how the recording
/// ended. A pure port of GNOME `source_report.py`/`capture_details.py` rules over
/// the raw files (JSON literals are validated as written, never coerced). It never
/// reads PCM, paths or device identities.
public struct RecordingDetailsReport: Equatable, Sendable {
    public enum Lifecycle: Sendable { case recording, saving, saved }
    /// A catalog phrase with typed values, rendered in the UI language.
    public struct Line: Equatable, Sendable {
        public enum Part: Equatable, Sendable { case text(String), catalog(String), duration(Int64), position(Int64) }
        public let id: String?
        public let values: [String:Part]
        /// For the dropped-audio line: "<label>: <duration>".
        public let label: Part?
        init(_ id: String, _ values: [String:Part] = [:]) { self.id = id; self.values = values; label = nil }
        init(text: Part) { id = nil; values = [:]; label = text }
        init(label: Part, value: Part) { id = nil; values = ["value":value]; self.label = label }
        public func render(language: CassiniLanguage, locale: Locale) -> String {
            func part(_ value: Part) -> String {
                switch value {
                case .text(let text): return text
                case .catalog(let id): return LibraryLocalization.shared.text(id,language:language,locale:locale)
                case .duration(let ms): return LibraryFormat.meetingDuration(ms,locale:locale,language:language)
                case .position(let ms): return LibraryFormat.position(ms,locale:locale,language:language)
                }
            }
            if let id { return LibraryLocalization.shared.text(id,values.mapValues(part),language:language,locale:locale) }
            if let label, let value = values["value"] { return part(label) + ": " + part(value) }
            return label.map(part) ?? ""
        }
    }
    public struct SourceRow: Equatable, Sendable {
        public let line: Line
        /// An expected source that failed, or (once final) produced no or little audio.
        public let problem: Bool
        public let gapLines: [Line]
    }
    public let title: Line
    public let subtitle: Line?
    /// "Updates while recording", only while recording.
    public let updates: Bool
    /// Empty means the details.sources.empty state.
    public let sources: [SourceRow]
    public let notes: [Line]
    public let ended: Line
    public let endKnown: Bool

    /// Every catalog id this report can emit (checked against the catalog in tests).
    public static let catalogIDs: [String] = ["details.title","details.liveSubtitle","details.updates","details.unknown",
        "details.sources.title","details.sources.captured","details.sources.neverAudio","details.sources.lowAudio","details.sources.failed",
        "details.sources.notSelected","details.sources.gap","details.sources.empty","details.sources.overlap","details.health.dropped",
        "common.yourMicrophone","recordFirst.sound.title","details.source.unknown","details.end.title","details.end.recording",
        "details.end.saving","details.end.at","recording.sourceProblem"] + CaptureEndReason.allCases.map { "details.end."+$0.rawValue }

    public struct Inputs: Sendable {
        public var lifecycle: Lifecycle
        public var title: String
        public var session: JSON?
        public var captureRecord: JSON?
        public var storedEnd: JSON?
        public var sourceSpansSeparated: Bool
        public var transcriptDone: Bool
        public init(lifecycle: Lifecycle, title: String, session: JSON?, captureRecord: JSON? = nil, storedEnd: JSON? = nil,
                    sourceSpansSeparated: Bool = false, transcriptDone: Bool = false) {
            self.lifecycle = lifecycle; self.title = title; self.session = session; self.captureRecord = captureRecord
            self.storedEnd = storedEnd; self.sourceSpansSeparated = sourceSpansSeparated; self.transcriptDone = transcriptDone
        }
        /// Bounded, symlink-refusing reads of session.json and meeting.json in a meeting folder.
        public static func load(folder: URL, lifecycle: Lifecycle, title: String, transcriptDone: Bool) -> Inputs {
            func read(_ name: String, limit: Int) -> JSON? {
                let fd = open(folder.appendingPathComponent(name).path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { return nil }
                let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
                var info = stat()
                guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
                      let data = try? handle.read(upToCount:limit + 1), data.count <= limit else { return nil }
                return try? JSONParser.parse(data)
            }
            let meeting = read("meeting.json",limit:1_048_576)
            let details = meeting?["recordingDetails"]
            return .init(lifecycle:lifecycle,title:title,session:read("session.json",limit:8_388_608),captureRecord:details?["captureRecord"],
                         storedEnd:details?["end"],sourceSpansSeparated:details?["writingDown"]?["sourceSpansSeparated"]?.bool == true,transcriptDone:transcriptDone)
        }
    }

    public init(_ input: Inputs) {
        let recording = input.lifecycle == .recording
        let final = input.lifecycle == .saved
        title = .init("details.title")
        subtitle = recording ? .init("details.liveSubtitle",["title":.text(input.title)]) : nil
        updates = recording
        // A well-formed live record wins even when it then fails validation (no fallback).
        let live = Self.liveRecord(input.session)
        let record = live ?? input.captureRecord
        var rows: [SourceRow] = []
        if let record, let sources = Self.validSources(record,requireVersion:live == nil) {
            // Track facts come from the session, or from the record when the session is gone.
            let tracks = input.session?["tracks"] ?? record["tracks"]
            rows = sources.map { Self.row($0,tracks:tracks,final:final) }
        }
        sources = rows
        notes = input.sourceSpansSeparated && input.transcriptDone ? [.init("details.sources.overlap")] : []
        (ended,endKnown) = Self.end(input,events:input.session?["events"] ?? record?["events"])
    }

    // MARK: Source record

    static func liveRecord(_ session: JSON?) -> JSON? {
        guard let outcome = session?["captureOutcome"], outcome.object != nil, outcome["sources"]?.array != nil else { return nil }
        return outcome
    }
    static let kinds: Set<String> = ["microphone","system","application","local","remote","media","tab"]
    static let outcomes: Set<String> = ["captured","neverAudio","lowAudio","failed"]
    static let safe: Double = 9_007_199_254_740_991
    static func identity(_ value: JSON?) -> String? {
        guard let text = value?.string, !text.isEmpty, text.utf8.count <= 200 else { return nil }; return text
    }
    /// Whole-record validation; any malformed known field rejects the record.
    static func validSources(_ record: JSON, requireVersion: Bool) -> [JSON]? {
        guard record.object != nil else { return nil }
        if requireVersion { guard case .number(let literal)? = record["version"], literal == "1" else { return nil } }
        guard let sources = record["sources"]?.array else { return nil }
        for row in sources {
            guard row.object != nil, identity(row["sourceTrackId"]) != nil,
                  let kind = row["kind"]?.string, kinds.contains(kind),
                  let label = row["label"]?.string, label.unicodeScalars.count <= 200,
                  let outcome = row["captureOutcome"]?.string, outcomes.contains(outcome),
                  case .number? = row["audioMs"], let ms = row["audioMs"]?.double, ms.isFinite, (0...safe).contains(ms),
                  let ids = row["trackIds"]?.array, ids.allSatisfy({ identity($0) != nil }) else { return nil }
            if let expected = row["captureExpected"] { guard case .bool = expected else { return nil } }
        }
        return sources
    }
    static func name(_ row: JSON) -> Line.Part {
        switch row["kind"]?.string {
        case "microphone","local": return .catalog("common.yourMicrophone")
        case "system": return .catalog("recordFirst.sound.title")
        default:
            let collapsed = (row["label"]?.string ?? "").split(whereSeparator:\.isWhitespace).joined(separator:" ")
            return collapsed.isEmpty ? .catalog("details.source.unknown") : .text(String(collapsed.prefix(180)))
        }
    }
    static func row(_ row: JSON, tracks: JSON?, final: Bool) -> SourceRow {
        let expected = row["captureExpected"]?.bool != false
        let recorded = row["captureOutcome"]!.string!
        let outcome = expected ? recorded : "notSelected"
        let source = name(row), duration = Line.Part.duration(Int64(floor(row["audioMs"]!.double!)))
        let line: Line
        if !final && outcome == "neverAudio" { line = .init(text:source) }
        else {
            let shown = !final && outcome == "lowAudio" ? "captured" : outcome
            line = shown == "neverAudio" || shown == "failed" || shown == "notSelected"
                ? .init("details.sources."+shown,["source":source]) : .init("details.sources."+shown,["source":source,"duration":duration])
        }
        let problem = expected && (recorded == "failed" || (final && (recorded == "neverAudio" || recorded == "lowAudio")))
        var gaps: [Line] = []
        if expected {
            let ids = (row["trackIds"]?.array ?? []).compactMap(\.string)
            let padding = counter("gapFrames",ids:ids,tracks:tracks), dropped = counter("droppedFrames",ids:ids,tracks:tracks)
            if let padding, padding > 0 { gaps.append(.init("details.sources.gap",["source":source,"duration":.duration(Int64(floor(padding)))])) }
            if let dropped, dropped > 0, dropped != padding {
                gaps.append(.init(label:.catalog("details.health.dropped"),value:.duration(Int64(floor(dropped)))))
            }
        }
        return .init(line:line,problem:problem,gapLines:gaps)
    }
    /// Milliseconds of a per-track counter over a source's distinct tracks; nil when unknown.
    static func counter(_ field: String, ids: [String], tracks: JSON?) -> Double? {
        guard Set(ids).count == ids.count, let list = tracks?.array else { return nil }
        var total = 0.0
        for id in ids {
            let matches = list.filter { $0["id"]?.string == id }
            guard matches.count == 1, let track = matches.first else { return nil }
            guard case .number? = track["sampleRate"], let rate = track["sampleRate"]?.int, (8000...192000).contains(rate) else { return nil }
            var frames = 0.0
            if let value = track[field], !value.isNull {
                guard case .number(let literal) = value, let count = Double(literal), count.rounded() == count, (0...safe).contains(count),
                      !literal.contains("."), !literal.lowercased().contains("e") else { return nil }
                frames = count
            }
            total += frames * 1000 / Double(rate)
        }
        return total
    }

    // MARK: How it ended

    static func end(_ input: Inputs, events: JSON?) -> (Line,Bool) {
        switch input.lifecycle {
        case .recording: return (.init("details.end.recording"),true)
        case .saving: return (.init("details.end.saving"),true)
        case .saved: break
        }
        if let last = CaptureEvent.read(events).last, last.type == "end", let reason = last.reason, let at = last.atMs,
           CaptureEndReason(rawValue:reason) != nil {
            return (.init("details.end.at",["reason":.catalog("details.end."+reason),"time":.position(Int64(at.rounded(.down)))]),true)
        }
        if let end = input.storedEnd, let reason = end["reason"]?.string, CaptureEndReason(rawValue:reason) != nil {
            if case .number(let literal)? = end["atMs"], let at = Double(literal), at.rounded() == at, (0...safe).contains(at), !literal.contains(".") {
                return (.init("details.end.at",["reason":.catalog("details.end."+reason),"time":.position(Int64(at))]),true)
            }
            return (.init(text:.catalog("details.end."+reason)),true)
        }
        return (.init("details.unknown"),false)
    }

    // MARK: Recording page

    /// GNOME `live_problem(session)`: from session.json only. A failed expected source,
    /// or a microphone/system track that ended with an io problem.
    public static func liveSourceProblem(session: JSON?) -> Bool {
        if let live = liveRecord(session), let sources = validSources(live,requireVersion:false),
           sources.contains(where:{ $0["captureExpected"]?.bool != false && $0["captureOutcome"]?.string == "failed" }) { return true }
        return (session?["tracks"]?.array ?? []).contains {
            ["microphone","system"].contains($0["kind"]?.string ?? "") && $0["ended"]?.bool == true && $0["problemKind"]?.string == "io"
        }
    }
}
