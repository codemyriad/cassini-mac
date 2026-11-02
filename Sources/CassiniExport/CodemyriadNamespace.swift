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
        let session = received ? nil : (try? Data(contentsOf:meeting.folder.appendingPathComponent("session.json"))).flatMap { try? JSONParser.parse($0) }
        // namePrefix: chosen once; a persisted one is kept, otherwise names.py's choice now.
        var prefix: (value: String, source: JSON?)
        if let kept = raw["namePrefix"]?.string, LibraryNames.isPrefix(kept) {
            prefix = (kept,raw["namePrefixSource"])
        } else {
            let start: LibraryNames.Start
            let importUtc = Self.utc(received ? raw["received"]?["importedAtMs"]?.int.map { Date(timeIntervalSince1970:Double($0) / 1000) } ?? now : now)
            if received {
                start = .received(dateTag:dateTag,importUtc:importUtc,libraryTimeZone:zone.identifier)
            } else if let created = session?["createdAt"]?.string, (try? LibraryNames.parseUTC(created)) != nil {
                start = .capture(startUtc:created,utcOffsetMinutes:session?["startedAtUtcOffsetMinutes"]?.int,libraryTimeZone:zone.identifier)
            } else {
                start = .unknownStart(importUtc:importUtc,libraryTimeZone:zone.identifier)
            }
            let chosen = try LibraryNames.prefix(start)
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
