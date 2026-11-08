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
                case .duration(let ms): return LibraryFormat.detailsDuration(ms,locale:locale,language:language)
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
        /// R13 (D67.1): "{source}: no speech heard." after the gap lines. A role line, never a problem.
        public let silent: Line?
        /// D58.3: under the silent line of a native "This computer" source, "If others were
        /// speaking, check that Cassini can record this computer's sound.", which the sheet pairs
        /// with errors.othersPermission.action (Open System Settings). Derived, never stored.
        public var permissionHint: Line? = nil
        /// D69.2: "{source}: about {duration} is missing because the computer was too busy. That part
        /// is silent." A quiet line (never a problem, never amber), shown only when the source's
        /// summed D69 writer loss, rounded once, is at least 1 s.
        public var computerBusy: Line? = nil
        /// The lines in display order: the source's own line, its gap lines, the computer-busy line,
        /// the silent line, then the hint.
        public var lines: [Line] {
            [line] + gapLines + (computerBusy.map { [$0] } ?? []) + (silent.map { [$0] } ?? []) + (permissionHint.map { [$0] } ?? [])
        }
    }
    public let title: Line
    public let subtitle: Line?
    /// "Updates while recording", only while recording.
    public let updates: Bool
    /// Empty, with no refusal lines, means the details.sources.empty state.
    public let sources: [SourceRow]
    /// D58: one line per distinct refused side and code, after the source rows.
    public let refusals: [Line]
    public var sourcesEmpty: Bool { sources.isEmpty && refusals.isEmpty }
    /// D58.3: whether a source shows the system-audio permission hint (the meeting page links it
    /// from its "No speech was found" line).
    public var showsPermissionHint: Bool { sources.contains { $0.permissionHint != nil } }
    public let notes: [Line]
    public let ended: Line
    public let endKnown: Bool

    /// Every catalog id this report can emit (checked against the catalog in tests).
    public static let catalogIDs: [String] = ["details.title","details.liveSubtitle","details.updates","details.unknown",
        "details.othersRoute.mixedSite","details.sources.title","details.sources.captured","details.sources.neverAudio","details.sources.lowAudio","details.sources.lowAudio.underSecond","details.sources.failed","details.sources.silent",
        "details.sources.silent.othersPermissionHint",
        "details.sources.notSelected","details.sources.gap","details.sources.computerBusy","details.sources.empty","details.sources.overlap","details.health.dropped",
        "common.yourMicrophone","recordFirst.sound.title","details.source.unknown","details.end.title","details.end.recording",
        "details.end.saving","details.end.at","recording.sourceProblem","details.source.microphone","details.source.system","details.source.browser"]
        + (knownFallbackCauses.union(["other"]).sorted().map { "details.othersFallback.cause."+$0 })
        + CaptureEndReason.allCases.map { "details.end."+$0.rawValue } + refusedCodes.sorted().map { "details.sources.refused."+$0 }

    public struct Inputs: Sendable {
        public var lifecycle: Lifecycle
        public var title: String
        public var session: JSON?
        public var othersRoute: JSON? = nil
        public var captureRecord: JSON?
        public var storedEnd: JSON?
        public var sourceSpansSeparated: Bool
        public var transcriptDone: Bool
        /// recordingDetails.writingDown.silentTracks of the last completed write-down (D56, D67.3).
        public var silentTracks: Set<String>
        public init(lifecycle: Lifecycle, title: String, session: JSON?, captureRecord: JSON? = nil, storedEnd: JSON? = nil,
                    sourceSpansSeparated: Bool = false, transcriptDone: Bool = false, silentTracks: Set<String> = [], othersRoute: JSON? = nil) {
            self.lifecycle = lifecycle; self.title = title; self.session = session; self.captureRecord = captureRecord
            self.storedEnd = storedEnd; self.sourceSpansSeparated = sourceSpansSeparated; self.transcriptDone = transcriptDone
            self.othersRoute = othersRoute
            self.silentTracks = silentTracks
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
            let meeting = read("meeting.json",limit:MeetingMetadataLimit.bytes)
            let details = meeting?["recordingDetails"]
            // A malformed list is no list: no source reads as silent.
            let listed = details?["writingDown"]?["silentTracks"]?.array
            let silent = listed.flatMap { list in list.allSatisfy { RecordingDetailsReport.identity($0) != nil } ? Set(list.compactMap(\.string)) : nil } ?? []
            return .init(lifecycle:lifecycle,title:title,session:read("session.json",limit:SessionManifestLimit.bytes),captureRecord:details?["captureRecord"],
                         storedEnd:details?["end"],sourceSpansSeparated:details?["writingDown"]?["sourceSpansSeparated"]?.bool == true,transcriptDone:transcriptDone,
                         silentTracks:silent,othersRoute:details?["othersRoute"])
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
        let silent = input.transcriptDone ? input.silentTracks : nil
        var rows: [SourceRow] = [], recordValid = true, referencedTracks: Set<String> = []
        // Track facts come from the session, or from the record when the session is gone.
        let tracks = input.session?["tracks"] ?? record?["tracks"]
        if let record {
            if let sources = Self.validSources(record,requireVersion:live == nil) {
                rows = sources.map { Self.row($0,tracks:tracks,final:final,silentTracks:silent) }
                referencedTracks = Set(sources.flatMap { ($0["trackIds"]?.array ?? []).compactMap(\.string) })
            } else { recordValid = false }
        }
        // Native microphone/system spans are not bound to the browser's source-outcomes
        // ledger. Include them beside reported sources, once per track, so their received
        // audio, writer loss and silent-track facts are visible in browser calls too.
        if recordValid { rows += Self.nativeRows(tracks:tracks,final:final,silentTracks:silent,excluding:referencedTracks) }
        sources = rows
        // The session's list while it exists, else the captureRecord's verbatim copy.
        refusals = Self.refusalLines(input.session != nil ? input.session?["refusals"] : input.captureRecord?["refusals"])
        notes = (input.sourceSpansSeparated && input.transcriptDone ? [.init("details.sources.overlap")] : [])
            + (input.othersRoute?["source"]?.string == "system" && input.othersRoute?["reason"]?.string == "mixedSiteSignal" && Self.routeSite(input.othersRoute?["site"]) != nil ? [.init("details.othersRoute.mixedSite",["site":.text(input.othersRoute?["site"]?.string ?? "")])] : [])
            + Self.fallbackCauseLines(input.session?["events"] ?? record?["events"])
        (ended,endKnown) = Self.end(input,events:input.session?["events"] ?? record?["events"])
    }

    private static func routeSite(_ value: JSON?) -> String? {
        guard let text = value?.string, !text.isEmpty, text.count <= 200 else { return nil }
        return text
    }
    static let knownFallbackCauses: Set<String> = ["frameError","frameClosed","tabClosed","nativeHostError","startupError","transportClosed"]
    static func fallbackCauseLines(_ raw: JSON?) -> [Line] {
        var shown: Set<String> = [], result: [Line] = []
        for event in CaptureEvent.read(raw) where event.type == "othersSource" && event.source == "system" && event.reason == "lost" {
            let code = event.cause.map { knownFallbackCauses.contains($0.rawValue) ? $0.rawValue : "other" } ?? "other"
            if shown.insert(code).inserted { result.append(.init("details.othersFallback.cause."+code)) }
        }
        return result
    }

    // MARK: Source record

    static func liveRecord(_ session: JSON?) -> JSON? {
        guard let outcome = session?["captureOutcome"], outcome.object != nil, outcome["sources"]?.array != nil else { return nil }
        return outcome
    }
    static let kinds: Set<String> = ["microphone","system","application","local","remote","media","tab"]
    static let outcomes: Set<String> = ["captured","neverAudio","lowAudio","failed"]
    static let safe: Double = 9_007_199_254_740_991
    /// The capture format bound for a time within a recording (24 h + 1 min).
    static let endBound: Double = 86_460_000
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
    /// Whole milliseconds to show: a positive amount under 1 ms shows as the smallest one, never as
    /// nothing (L1 review).
    static func shown(_ ms: Double) -> Int64 { ms > 0 ? max(1,Int64(floor(ms))) : 0 }
    /// silentTracks is nil unless the transcript is done (R13.1).
    static func row(_ row: JSON, tracks: JSON?, final: Bool, silentTracks: Set<String>? = nil) -> SourceRow {
        let expected = row["captureExpected"]?.bool != false
        let recorded = row["captureOutcome"]!.string!
        let outcome = expected ? recorded : "notSelected"
        let source = name(row), duration = Line.Part.duration(shown(row["audioMs"]!.double!))
        let line: Line
        if !final && outcome == "neverAudio" { line = .init(text:source) }
        else {
            let shown = !final && outcome == "lowAudio" ? "captured" : outcome
            // D58.4: under one second the low-audio line says so in words, not as a rounded number.
            let underSecond = shown == "lowAudio" && row["audioMs"]!.double! < 1000
            line = shown == "neverAudio" || shown == "failed" || shown == "notSelected" || underSecond
                ? .init("details.sources."+shown+(underSecond ? ".underSecond" : ""),["source":source])
                : .init("details.sources."+shown,["source":source,"duration":duration])
        }
        let problem = expected && (recorded == "failed" || (final && (recorded == "neverAudio" || recorded == "lowAudio")))
        var gaps: [Line] = [], busy: Line? = nil
        if expected {
            let ids = (row["trackIds"]?.array ?? []).compactMap(\.string)
            let padding = counter("gapFrames",ids:ids,tracks:tracks), dropped = counter("droppedFrames",ids:ids,tracks:tracks)
            let writer = writerLoss(ids:ids,tracks:tracks)
            if let padding, padding > 0 { gaps.append(.init("details.sources.gap",["source":source,"duration":.duration(shown(padding))])) }
            // D69.2: writer loss is the quiet line below, so the dropped-audio line counts only the
            // audio the producer dropped (browser capture); native droppedFrames is writer padding.
            if let dropped {
                let residual = writer.map { max(0,dropped - $0.droppedMs) } ?? dropped
                if residual > 0, residual != padding {
                    gaps.append(.init(label:.catalog("details.health.dropped"),value:.duration(shown(residual))))
                }
            }
            if let writer, writer.roundedMs >= 1000 {
                busy = .init("details.sources.computerBusy",["source":source,"duration":.duration(Int64(writer.roundedMs))])
            }
        }
        // R13 (D67.1): a captured expected source whose every track was left out as silent by a
        // done write-down. neverAudio and lowAudio keep their own line only (R13.2).
        let ids = (row["trackIds"]?.array ?? []).compactMap(\.string)
        let silent: Line? = expected && recorded == "captured" && !ids.isEmpty && silentTracks.map({ set in ids.allSatisfy(set.contains) }) == true
            ? .init("details.sources.silent",["source":source]) : nil
        var result = SourceRow(line:line,problem:problem,gapLines:gaps,silent:silent)
        result.computerBusy = busy
        return result
    }
    /// D69.2: a source's summed D69 writer loss, rounded once (exact half-up across rates, as the
    /// writer rounds its stored sentence), and the part of its droppedFrames that is writer
    /// padding. Writer frames are the source's `writer` ranges; past an overflow marker a native
    /// track's droppedFrames (all writer padding) is the better count. Nil when unknown.
    static func writerLoss(ids: [String], tracks: JSON?) -> (roundedMs: UInt64, droppedMs: Double)? {
        guard Set(ids).count == ids.count, let list = tracks?.array else { return nil }
        var rates: [Int:UInt64] = [:], droppedMs = 0.0, totalMs = 0.0
        // Match the other Details counters: malformed or unsafe numbers are unknown.
        func framesCount(_ value: JSON?) -> UInt64? {
            guard case .number(let literal)? = value, let count = UInt64(literal), count <= UInt64(safe) else { return nil }
            return count
        }
        for id in ids {
            let matches = list.filter { $0["id"]?.string == id }
            guard matches.count == 1, let track = matches.first, let rate = track["sampleRate"]?.int, (8000...192000).contains(rate) else { return nil }
            var frames: UInt64 = 0, overflow = false
            if let gaps = track["gaps"], gaps.array == nil { return nil }
            for range in track["gaps"]?.array ?? [] {
                switch range["kind"]?.string {
                case "writer"?:
                    guard let count = framesCount(range["frames"]) else { return nil }
                    let sum = frames.addingReportingOverflow(count)
                    guard !sum.overflow, sum.partialValue <= UInt64(safe) else { return nil }
                    frames = sum.partialValue
                case "overflow"?: overflow = true
                default: break
                }
            }
            var dropped: UInt64 = 0
            if let value = track["droppedFrames"], !value.isNull {
                guard let count = framesCount(value) else { return nil }
                dropped = count
            }
            if overflow, ["microphone","system"].contains(track["kind"]?.string ?? "") { frames = max(frames,dropped) }
            let sum = rates[rate,default:0].addingReportingOverflow(frames)
            guard !sum.overflow, sum.partialValue <= UInt64(safe) else { return nil }
            rates[rate] = sum.partialValue
            totalMs += Double(frames) * 1000 / Double(rate)
            guard totalMs <= safe else { return nil }
            droppedMs += Double(min(frames,dropped)) * 1000 / Double(rate)
        }
        let rounded = WriterLoss.roundedMilliseconds(rates)
        guard rounded <= UInt64(safe) else { return nil }
        return (rounded,droppedMs)
    }
    /// D58.2 R3: one row per native kind (microphone, then this computer's sound) whose tracks
    /// received audio. The outcome follows the received duration as the capture ledger's does
    /// (CaptureOutcome: under 1000 ms is lowAudio), and row() then words it (live, low audio
    /// reads as captured). Gap and dropped lines follow as for any source. A side with no
    /// received audio has no row (a refusal line says why, D58). silentTracks as for row().
    static func nativeRows(tracks: JSON?, final: Bool, silentTracks: Set<String>? = nil, excluding: Set<String> = []) -> [SourceRow] {
        guard let list = tracks?.array else { return [] }
        return ["microphone","system"].compactMap { kind -> SourceRow? in
            var ids: [String] = [], received = 0.0
            for track in list where track["kind"]?.string == kind {
                guard let id = identity(track["id"]), !excluding.contains(id), let ms = receivedMs(track) else { continue }
                ids.append(id); received += ms
            }
            // CaptureOutcome's own comparison on the unrounded total; only the shown duration is floored.
            guard !ids.isEmpty, received > 0, received <= safe else { return nil }
            let outcome = received < 1000 ? "lowAudio" : "captured", audioMs = Double(shown(received))
            let source: JSON = .object([("sourceTrackId",.string(kind)),("kind",.string(kind)),("label",.string("")),
                                        ("captureOutcome",.string(outcome)),("audioMs",.number(String(Int64(audioMs)))),
                                        ("trackIds",.array(ids.map { .string($0) }))])
            var shown = row(source,tracks:tracks,final:final,silentTracks:silentTracks)
            // D58.3: a denied system-audio permission gives the tap digital silence, which a quiet
            // call also gives, so after Stop a captured native "This computer" side whose every
            // track a done write-down left out as silent adds a conditional hint (never live).
            if kind == "system", final, shown.silent != nil { shown.permissionHint = .init("details.sources.silent.othersPermissionHint") }
            return shown
        }
    }
    /// Received milliseconds of one native track, never counting padding; nil when unknown.
    /// The writer's receivedFrames (admitted PCM, no padding) wins when present and valid. An
    /// older file without it subtracts its stored padding ranges (gaps: jump, input, prefix
    /// and writer), counting nothing after an overflow marker (unknown to the track end);
    /// gapFrames repeats the jump and input ranges, so it is used only when gaps is absent,
    /// together with droppedFrames: before D52 the sink padded the audio it lost with silence.
    /// Milliseconds are frames * 1000 / rate, as the ledger computes them.
    static func receivedMs(_ track: JSON) -> Double? {
        guard let rate = track["sampleRate"]?.int, (8000...192000).contains(rate), let frames = count(track["frames"]) else { return nil }
        let hz = Double(rate), ms = { (frames: Double) in frames * 1000 / hz }
        if let stored = track["receivedFrames"] {
            guard let received = count(stored), received <= frames else { return nil }
            return ms(received)
        }
        guard let gaps = track["gaps"] else { return ms(max(0,frames - (count(track["gapFrames"]) ?? 0) - (count(track["droppedFrames"]) ?? 0))) }
        guard let ranges = gaps.array else { return nil }
        var padding = 0.0, counted = frames
        for range in ranges {
            if range["kind"]?.string == "overflow" {
                guard let at = range["atMs"]?.double, at.isFinite, let start = track["startOffsetMs"]?.double, start.isFinite else { return nil }
                counted = min(counted,max(0,((at - start) * hz / 1000).rounded(.down)))
            } else {
                guard let padded = count(range["frames"]) else { return nil }
                padding += padded
            }
        }
        return ms(max(0,counted - padding))
    }
    /// A whole, non-negative JSON number within the safe range.
    static func count(_ value: JSON?) -> Double? {
        guard case .number(let literal)? = value, let count = Double(literal), count.rounded() == count, (0...safe).contains(count) else { return nil }
        return count
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
        return total <= safe ? total : nil
    }

    // MARK: Refusals (D58)

    static let refusedCodes: Set<String> = ["permissionDenied","deviceUnavailable","startRejected"]
    static let refusalSources = ["me":"details.source.microphone","others":"details.source.system","browser":"details.source.browser"]
    static func token(_ value: JSON?) -> String? {
        guard let text = value?.string else { return nil }
        let scalars = text.unicodeScalars
        guard (1...32).contains(scalars.count), scalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) }) else { return nil }
        return text
    }
    /// Lenient: a value that is not a list is ignored as a whole; an entry the session schema's
    /// item rejects is skipped (patterns on the whole string; null detail or message is absent;
    /// a message of at most 200 code points).
    static func wellFormed(_ stored: JSON?) -> [JSON] {
        guard let list = stored?.array else { return [] }
        return list.filter { entry in
            guard entry.object != nil, case .number(let literal)? = entry["atMs"], let at = Double(literal), at.isFinite,
                  (0...86_460_000).contains(at), token(entry["side"]) != nil, token(entry["code"]) != nil else { return false }
            if let detail = entry["detail"], !detail.isNull, token(detail) == nil { return false }
            if let message = entry["message"], !message.isNull {
                guard let text = message.string, text.unicodeScalars.count <= 200 else { return false }
            }
            return true
        }
    }
    /// Copy details: every well-formed entry, in stored order, exactly as stored (no merging,
    /// re-cut or normalization).
    public static func refusalCopy(_ stored: JSON?) -> [JSON] { wellFormed(stored) }
    /// One line per distinct shown line, in first-occurrence order: refused.<code> for the three
    /// known codes, details.sources.failed for any other (a stored startFailed included). An
    /// unknown side is not shown; detail, message and unknown members never change the lines.
    public static func refusalLines(_ stored: JSON?) -> [Line] { refusalLinesAndRoles(stored).lines }
    static func refusalLinesAndRoles(_ stored: JSON?) -> (lines: [Line], roles: Set<String>) {
        var lines: [Line] = [], roles: Set<String> = []
        for entry in wellFormed(stored) {
            let side = entry["side"]!.string!, code = entry["code"]!.string!
            guard let source = refusalSources[side] else { continue }
            // A browser refusal is The others' audio too.
            roles.insert(side == "browser" ? "others" : side)
            let line = Line(refusedCodes.contains(code) ? "details.sources.refused."+code : "details.sources.failed",["source":.catalog(source)])
            if !lines.contains(line) { lines.append(line) }
        }
        return (lines,roles)
    }
    /// The Audio sources lines after the source rows: refusal lines, notSelected for each listed
    /// side without a refusal line for its role, and the empty state only when nothing else shows.
    public static func sourceLines(stored: JSON?, notSelected: [String], hasRows: Bool) -> [Line] {
        let (refused,roles) = refusalLinesAndRoles(stored)
        var lines = refused
        for side in notSelected where !roles.contains(side) {
            if let source = refusalSources[side] { lines.append(.init("details.sources.notSelected",["source":.catalog(source)])) }
        }
        if !hasRows && lines.isEmpty { lines.append(.init("details.sources.empty")) }
        return lines
    }

    // MARK: How it ended

    static func end(_ input: Inputs, events: JSON?) -> (Line,Bool) {
        switch input.lifecycle {
        case .recording: return (.init("details.end.recording"),true)
        case .saving: return (.init("details.end.saving"),true)
        case .saved: break
        }
        // An end time past the format bound is not a valid end: fall back to the stored end, then unknown.
        if let last = CaptureEvent.read(events).last, last.type == "end", let reason = last.reason, let at = last.atMs,
           at.isFinite, (0...endBound).contains(at), CaptureEndReason(rawValue:reason) != nil {
            // D69.2: writer-only loss has no error end state. D69 stores reason error over the stop's
            // own: a native stop passes none, so it was the user's; a browser capture's is lost.
            if reason == CaptureEndReason.error.rawValue, let session = input.session, WriterLoss.isWriterOnly(session) {
                guard session["source"]?.string != "chromium", liveRecord(session) == nil else { return (.init("details.unknown"),false) }
                return (.init("details.end.at",["reason":.catalog("details.end.user"),"time":.position(Int64(at.rounded(.down)))]),true)
            }
            return (.init("details.end.at",["reason":.catalog("details.end."+reason),"time":.position(Int64(at.rounded(.down)))]),true)
        }
        if let end = input.storedEnd, let reason = end["reason"]?.string, CaptureEndReason(rawValue:reason) != nil {
            if case .number(let literal)? = end["atMs"], let at = Double(literal), at.rounded() == at, (0...endBound).contains(at), !literal.contains(".") {
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
