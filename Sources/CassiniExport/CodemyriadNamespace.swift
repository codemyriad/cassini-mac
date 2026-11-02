// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import CassiniLibrary

/// R65 (D55): the app's own `x["codemyriad.io"]` (schema 1) in an exported Cassini file, per
/// cassini-coordination ux-draft/library-v2/MAPPING.md and x-schema.json. It mirrors
/// meeting.json losslessly (numbers keep their literal text), adds the session link,
/// automaticTitle and, for a recording, the track/span map with the D52.4 gap facts.
/// The Mac Library itself stays on meeting.json; this is only the file's copy.
enum CodemyriadNamespace {
    static let key = "codemyriad.io"
    /// meeting.json members placed in `meeting`; all other members (except the session
    /// link, notes and published) go to `passthrough`.
    static let meetingMembers = ["version","title","titleSource","speakers","speakerMerges","transcript","etaMinutes","error","quoteOverride","received","recordingDetails"]
    static let linkMembers: Set<String> = ["id","revision","notes","namePrefix","namePrefixSource","published"]

    /// nil when the folder has no readable meeting.json with an id and a revision.
    static func make(_ meeting: LibraryMeeting, dateTag: String?, originalTitle: String?, now: Date, zone: TimeZone) throws -> JSON? {
        // Before its first metadata write a folder has no meeting.json: it implies the default one.
        let data = (try? Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json")))
            ?? (try? JSONSerialization.data(withJSONObject:MeetingMetadataWriter.defaultDocument(id:meeting.id),options:[.sortedKeys]))
        guard let data, let raw = try? JSONParser.parse(data), let members = raw.object,
              let sessionID = raw["id"]?.string, let revision = raw["revision"], revision.int != nil else { return nil }
        let received = raw["received"]?.object != nil
        var inMeeting: [(String,JSON)] = [], passthrough: [(String,JSON)] = []
        for (name,value) in members where !linkMembers.contains(name) {
            if meetingMembers.contains(name) { inMeeting.append((name,value)) } else { passthrough.append((name,value)) }
        }
        let session = received ? nil : Self.session(meeting)
        // namePrefix: chosen once and saved into meeting.json on first export (D55.1);
        // a folder whose metadata is read-only gets the same choice without saving it.
        var prefix: (value: String, source: JSON?)
        if let kept = raw["namePrefix"]?.string, LibraryNames.isPrefix(kept) {
            prefix = (kept,raw["namePrefixSource"])
        } else {
            let chosen = try choosePrefix(raw:raw,session:session,dateTag:dateTag,now:now,zone:zone)
            prefix = (chosen.namePrefix,.string(chosen.source))
        }
        var fields: [(String,JSON)] = [("schema",.number("1")),("sessionId",.string(sessionID)),("origin",.string(received ? "Received" : "Recording")),
                                       ("namePrefix",.string(prefix.value))]
        if let source = prefix.source { fields.append(("namePrefixSource",source)) }
        fields.append(("revision",revision))
        fields.append(("meeting",.object(inMeeting)))
        if !passthrough.isEmpty { fields.append(("passthrough",.object(passthrough))) }
        let automatic = received ? originalTitle : session?["title"]?.string
        fields.append(("automaticTitle",automatic.map { .string(String(String.UnicodeScalarView($0.unicodeScalars.prefix(500)))) } ?? .null))
        if !received, let tracks = session?["tracks"]?.array { fields.append(("tracks",.array(tracks.prefix(64).compactMap(track)))) }
        return .object(fields)
    }
    private static func session(_ meeting: LibraryMeeting) -> JSON? {
        (try? Data(contentsOf:meeting.folder.appendingPathComponent("session.json"))).flatMap { try? JSONParser.parse($0) }
    }
    /// names.py's choice for a meeting without a persisted prefix.
    static func choosePrefix(raw: JSON, session: JSON?, dateTag: String?, now: Date, zone: TimeZone) throws -> LibraryNames.Prefix {
        let received = raw["received"]?.object != nil
        let importUtc = utc(received ? raw["received"]?["importedAtMs"]?.int.map { Date(timeIntervalSince1970:Double($0) / 1000) } ?? now : now)
        let start: LibraryNames.Start
        if received {
            start = .received(dateTag:dateTag,importUtc:importUtc,libraryTimeZone:zone.identifier)
        } else if let created = session?["createdAt"]?.string, (try? LibraryNames.parseUTC(created)) != nil {
            start = .capture(startUtc:created,utcOffsetMinutes:session?["startedAtUtcOffsetMinutes"]?.int,libraryTimeZone:zone.identifier)
        } else {
            start = .unknownStart(importUtc:importUtc,libraryTimeZone:zone.identifier)
        }
        return try LibraryNames.prefix(start)
    }
    /// D55.1: the namePrefix is chosen once, on the first export, and saved into meeting.json,
    /// so later exports keep the same name. An existing one is never recomputed.
    static func persistNamePrefix(_ meeting: LibraryMeeting, dateTag: String?, now: Date, zone: TimeZone) throws {
        guard !meeting.metadataReadOnly else { return }
        let stored = (try? Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json"))).flatMap { try? JSONParser.parse($0) }
        if let kept = stored?["namePrefix"]?.string, LibraryNames.isPrefix(kept) { return }
        let raw = stored ?? (try? JSONParser.parse(JSONSerialization.data(withJSONObject:MeetingMetadataWriter.defaultDocument(id:meeting.id)))) ?? .object([])
        let chosen = try choosePrefix(raw:raw,session:raw["received"]?.object != nil ? nil : session(meeting),dateTag:dateTag,now:now,zone:zone)
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
            $0["namePrefix"] = chosen.namePrefix; $0["namePrefixSource"] = chosen.source
        }
    }
    /// D55.1: Mac is a writer of this namespace too. In a schema-1 copy from another writer,
    /// the user's changes on Mac (title and titleSource, speaker names) replace those members
    /// in place and bump its revision; everything else stays verbatim. With no change, or an
    /// unknown schema, the original comes back unchanged (byte-for-byte).
    static func merged(_ original: JSON, with meeting: LibraryMeeting) -> JSON {
        guard original["schema"] == .number("1"), var copy = original["meeting"], copy.object != nil,
              let data = try? Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json")),
              let raw = try? JSONParser.parse(data) else { return original }
        var changed = false
        func set(_ key: String, _ value: JSON) {
            guard copy[key] != value, let next = try? copy.setting(key,to:value) else { return }
            copy = next; changed = true
        }
        // A rename is titleSource "user"; a received title cleared on Mac is null with
        // "meeting-window" (import always stores a title, so null only follows a clear).
        if raw["titleSource"]?.string == "user", let title = raw["title"], title.string != nil {
            set("title",title); set("titleSource",.string("user"))
        } else if raw["titleSource"]?.string == "meeting-window", raw["title"] == .null, copy["title"] != .null {
            set("title",.null); set("titleSource",.string("meeting-window"))
        }
        // Speaker names the user set or cleared on Mac, matched by the original speaker id.
        if var speakers = copy["speakers"]?.array {
            var edited = false
            for mine in raw["speakers"]?.array ?? [] where mine["provenance"]?.string == "user" || mine["nameCleared"] == .bool(true) {
                guard let id = mine["id"]?.string, let index = speakers.firstIndex(where:{ $0["id"]?.string == id }) else { continue }
                var entry = speakers[index]
                for key in ["name","provenance","nameCleared"] {
                    if let value = mine[key], entry[key] != value, let next = try? entry.setting(key,to:value) { entry = next; edited = true }
                }
                speakers[index] = entry
            }
            if edited { set("speakers",.array(speakers)) }
        }
        guard changed, let revision = original["revision"]?.int, revision < 9007199254740991,
              let result = try? original.setting("meeting",to:copy).setting("revision",to:.number(String(revision + 1))) else { return original }
        return result
    }
    /// meeting.json notes verbatim (nil when unreadable or empty).
    static func rawNotes(_ meeting: LibraryMeeting) -> JSON? {
        guard let data = try? Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json")),
              let notes = (try? JSONParser.parse(data))?["notes"], let list = notes.array, !list.isEmpty else { return nil }
        return notes
    }
    /// One session.json track as a single-span entry, with its D52.4 gap facts (provisional, S-12 §4.3).
    private static func track(_ raw: JSON) -> JSON? {
        guard let id = raw["id"]?.string, let file = raw["file"]?.string, let rate = raw["sampleRate"], rate.int != nil else { return nil }
        var span: [(String,JSON)] = [("file",.string(file)),("sampleRate",rate)]
        if let channels = raw["channels"] { span.append(("channels",channels)) }
        span.append(("frames",raw["frames"] ?? .number("0")))
        span.append(("startOffsetMs",raw["startOffsetMs"] ?? .null))
        var fields: [(String,JSON)] = [("id",.string(id))]
        if let kind = raw["kind"] { fields.append(("kind",kind)) }
        if let source = raw["sourceTrackId"] { fields.append(("sourceTrackId",source)) }
        fields.append(("spans",.array([.object(span)])))
        for name in ["gaps","gapFrames","droppedFrames"] { if let value = raw[name] { fields.append((name,value)) } }
        return .object(fields)
    }
    private static func utc(_ date: Date) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; iso.timeZone = TimeZone(identifier:"UTC")
        return iso.string(from:date)
    }
}
