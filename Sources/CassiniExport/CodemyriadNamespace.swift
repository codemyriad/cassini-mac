// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
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
    /// Mac-local meeting.json member, never exported: for a received file carrying another
    /// writer's schema-1 namespace, the revision Mac last gave that namespace and a digest of
    /// what it wrote then (`{"revision": n, "sha256": hex}`). See `merged`.
    static let baselineMember = "codemyriadExport"

    /// nil when the folder has no readable meeting.json with an id and a revision.
    static func make(_ meeting: LibraryMeeting, dateTag: String?, originalTitle: String?, now: Date, zone: TimeZone) throws -> JSON? {
        // Before its first metadata write a folder has no meeting.json: it implies the default one.
        let data = (try? Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json")))
            ?? (try? JSONSerialization.data(withJSONObject:MeetingMetadataWriter.defaultDocument(id:meeting.id),options:[.sortedKeys]))
        guard let data, let raw = try? JSONParser.parse(data), let members = raw.object,
              let sessionID = raw["id"]?.string, let revision = raw["revision"], revision.int != nil else { return nil }
        let received = raw["received"]?.object != nil
        var inMeeting: [(String,JSON)] = [], passthrough: [(String,JSON)] = []
        for (name,value) in members where !linkMembers.contains(name) && name != baselineMember {
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
        // Metadata this app cannot validate is never rewritten; the export still goes ahead.
        guard !meeting.metadataReadOnly, !meeting.issues.contains(.invalidMetadata) else { return }
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
    /// in place, everything else stays verbatim. nil for an unknown schema or an unusable
    /// revision: the caller keeps the original unchanged (byte-for-byte).
    ///
    /// Revision (MAPPING Q9, higher wins): a notes change counts too, since a rebuild takes
    /// notes from x["gocassini.com"]; notes as the import kept them (`LibraryImport.importedNotes`)
    /// are no change. Each export whose content (meeting copy and notes) differs from the last
    /// one Mac exported takes the next revision above both the original and that baseline; an
    /// export with the same content reuses it, and an unchanged meeting keeps the original.
    /// The content is read, and the baseline compared and advanced, under the folder lock, so
    /// a revision never names two contents. Returns the notes to write with it.
    static func merged(_ original: JSON, with meeting: LibraryMeeting, originalNotes: JSON?) throws -> (namespace: JSON, notes: JSON?)? {
        guard original["schema"] == .number("1"), original["meeting"]?.object != nil,
              let base = original["revision"]?.int, (0..<maxRevision).contains(base) else { return nil }
        let imported = NSArray(array:LibraryImport.importedNotes(originalNotes))
        let url = meeting.folder.appendingPathComponent("meeting.json")
        /// The decision for meeting.json `raw` and the saved baseline; `save` is the new baseline.
        func decide(_ raw: JSON?, saved: (revision: Int, sha256: String)?) throws -> (namespace: JSON, notes: JSON?, save: [String:Any]?) {
            let (copy,changed) = edits(original["meeting"]!,raw:raw)
            let notes = raw?["notes"].flatMap { $0.array?.isEmpty == false ? $0 : nil }
            let notesChanged = !noteValue(notes).isEqual(to:imported as! [Any])
            if !changed, !notesChanged, saved == nil { return (original,notes,nil) }
            let digest = try Self.digest(copy,notes:notes)
            if let saved, saved.sha256 == digest { return (try original.setting("meeting",to:copy).setting("revision",to:.number(String(saved.revision))),notes,nil) }
            let last = max(base,saved?.revision ?? base)
            guard last < maxRevision else { return (original,notes,nil) }
            return (try original.setting("meeting",to:copy).setting("revision",to:.number(String(last + 1))),notes,["revision":last + 1,"sha256":digest])
        }
        func baseline(_ value: JSON?) -> (revision: Int, sha256: String)? {
            guard let revision = value?["revision"]?.int, (0...maxRevision).contains(revision), let sha = value?["sha256"]?.string else { return nil }
            return (revision,sha)
        }
        // Metadata this app must not rewrite: nothing can change it on Mac either, so the
        // decision is stable without saving.
        if meeting.metadataReadOnly || meeting.issues.contains(.invalidMetadata) {
            let raw = (try? Data(contentsOf:url)).flatMap { try? JSONParser.parse($0) }
            let result = try decide(raw,saved:baseline(raw?[baselineMember]))
            return (result.namespace,result.notes)
        }
        var result: (namespace: JSON, notes: JSON?)?
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction(skippingUnchanged:true) { document in
            // Under the folder lock: meeting.json as it is now, number literals intact.
            let raw = (try? Data(contentsOf:url)).flatMap { try? JSONParser.parse($0) }
            let decided = try decide(raw,saved:baseline(raw?[baselineMember]))
            if let save = decided.save { document[baselineMember] = save }
            result = (decided.namespace,decided.notes)
        }
        return result
    }
    static let maxRevision = 9007199254740991
    /// The user's Mac edits (title, speaker names) applied to another writer's meeting copy.
    private static func edits(_ original: JSON, raw: JSON?) -> (copy: JSON, changed: Bool) {
        var copy = original, changed = false
        guard let raw else { return (copy,false) }
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
                // Saving a name removes an earlier clear (nameCleared goes only with unnamed).
                if mine["nameCleared"] == nil, mine["name"]?.string != nil, entry["nameCleared"] != nil,
                   let next = try? entry.setting("nameCleared",to:nil) { entry = next; edited = true }
                speakers[index] = entry
            }
            if edited { set("speakers",.array(speakers)) }
        }
        return (copy,changed)
    }
    /// Notes as a Foundation value, so equal notes compare equal whatever their number spelling.
    private static func noteValue(_ notes: JSON?) -> NSArray {
        guard let notes, notes.array?.isEmpty == false, let data = try? notes.encoded(),
              let value = try? JSONSerialization.jsonObject(with:data) as? NSArray else { return [] }
        return value
    }
    private static func digest(_ copy: JSON, notes: JSON?) throws -> String {
        var data = try copy.encoded()
        data.append(0)
        data.append(try JSONSerialization.data(withJSONObject:noteValue(notes),options:[.sortedKeys]))
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
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
