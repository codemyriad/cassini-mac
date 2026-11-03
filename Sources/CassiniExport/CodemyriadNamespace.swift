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
    /// what it wrote then (`revision`, `sha256`; see `merged`); for a meeting without a title,
    /// the untitled fallback in the language of its first export (`untitledTitle`, D65, Q6b).
    static let baselineMember = "codemyriadExport"

    /// #116 r3: the meeting changed while this export read it (meeting.json's revision moved
    /// since the snapshot): the export reads it again.
    struct MetadataChanged: Error {}
    /// meeting.json as it is now, checked against the revision the export's snapshot saw.
    static func current(_ meeting: LibraryMeeting) throws -> JSON? {
        let raw = (try? Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json"))).flatMap { try? JSONParser.parse($0) }
        guard unchanged(raw,since:meeting) else { throw MetadataChanged() }
        return raw
    }
    /// meeting.json is still at the revision the snapshot saw. Metadata the snapshot could not
    /// validate (or may not rewrite) has no revision there; Mac never writes it, so it counts.
    static func unchanged(_ raw: JSON?, since meeting: LibraryMeeting) -> Bool {
        if meeting.metadataRevision == nil, meeting.metadataReadOnly || meeting.issues.contains(.invalidMetadata) { return true }
        return raw?["revision"]?.int.map(Int64.init) == meeting.metadataRevision
    }
    /// nil when the folder has no readable meeting.json with an id and a revision. `stored`:
    /// meeting.json as read for this export (`current`).
    /// Only from a real meeting.json: an implied default one has no revision of its own.
    static func make(_ meeting: LibraryMeeting, stored raw: JSON, dateTag: String?, originalTitle: String?, now: Date, zone: TimeZone) throws -> JSON? {
        guard let members = raw.object,
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
    /// The untitled fallback saved at the first export (nil when none was saved).
    static func untitled(_ stored: JSON?) -> String? {
        stored?[baselineMember]?["untitledTitle"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }
    /// D55.1: the namePrefix is chosen once, on the first export, and saved into meeting.json,
    /// so later exports keep the same name. An existing one is never recomputed. D65 (Q6b): a
    /// meeting without a title saves its untitled fallback, in the language of that export, too.
    static func persistNamePrefix(_ meeting: LibraryMeeting, dateTag: String?, now: Date, zone: TimeZone) throws {
        // Metadata this app cannot validate is never rewritten; the export still goes ahead.
        guard !meeting.metadataReadOnly, !meeting.issues.contains(.invalidMetadata) else { return }
        let stored = (try? Data(contentsOf:meeting.folder.appendingPathComponent("meeting.json"))).flatMap { try? JSONParser.parse($0) }
        let keptPrefix = stored?["namePrefix"]?.string.map(LibraryNames.isPrefix) ?? false
        let needsUntitled = meeting.titleIsUntitled && untitled(stored) == nil
        if keptPrefix && !needsUntitled { return }
        let raw = stored ?? (try? JSONParser.parse(JSONSerialization.data(withJSONObject:MeetingMetadataWriter.defaultDocument(id:meeting.id)))) ?? .object([])
        let chosen = keptPrefix ? nil : try choosePrefix(raw:raw,session:raw["received"]?.object != nil ? nil : session(meeting),dateTag:dateTag,now:now,zone:zone)
        try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction {
            // A folder without meeting.json whose transcript.json the Library reads as done
            // (R2.3/R3) keeps those words: the created meeting.json references them.
            if stored == nil, meeting.state.transcript == .done {
                $0["transcript"] = ["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
            }
            if let chosen { $0["namePrefix"] = chosen.namePrefix; $0["namePrefixSource"] = chosen.source }
            if needsUntitled {
                var baseline = $0[baselineMember] as? [String:Any] ?? [:]
                baseline["untitledTitle"] = meeting.title; $0[baselineMember] = baseline
            }
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
    /// `importedTranscript`: the transcript state import stored for this file
    /// (`LibraryImport.importedTranscript`); Mac's transcription state counts only once it differs.
    /// `body`: a digest of the words this file carries, so other words never share a revision.
    /// meeting.json must still be at `meeting.metadataRevision` (else `MetadataChanged`).
    /// `bodyMatchesOriginal`: the file carries the original's words unchanged (else that is a
    /// change too); `damaged`: the export read the words as damaged (the namespace says so).
    /// D65: a namespace this app can't advance safely (unknown schema, malformed, a revision
    /// outside 0...2^53-1, or one at the ceiling that a change would have to pass) is refused
    /// with `newerFormat`.
    static func merged(_ original: JSON, with meeting: LibraryMeeting, originalNotes: JSON?,
                       importedTranscript: [String:Any]? = nil, body: String = "", bodyMatchesOriginal: Bool = true,
                       damaged: Bool = false) throws -> (namespace: JSON, notes: JSON?) {
        guard original["schema"] == .number("1"), original["meeting"]?.object != nil,
              let base = original["revision"]?.int, (0...maxRevision).contains(base) else { throw MeetingExportError.newerFormat }
        let url = meeting.folder.appendingPathComponent("meeting.json")
        /// The decision for meeting.json `raw` and the saved baseline; `save` is the new baseline.
        func decide(_ raw: JSON?, saved: (revision: Int, sha256: String)?) throws -> (namespace: JSON, notes: JSON?, save: [String:Any]?) {
            guard unchanged(raw,since:meeting) else { throw MetadataChanged() }
            var (copy,changed) = edits(original["meeting"]!,raw:raw,importedTranscript:importedTranscript ?? ["status":"none","reference":NSNull()])
            if damaged, let marked = try? marking(.object([("meeting",copy)]),damaged:true)["meeting"], marked != copy { copy = marked; changed = true }
            let (notes,notesChanged) = exportNotes(local:localNotes(raw),original:originalNotes)
            if !changed, !notesChanged, bodyMatchesOriginal, saved == nil { return (original,notes,nil) }
            let digest = try Self.digest(copy,notes:notes,body:body)
            if let saved, saved.sha256 == digest { return (try original.setting("meeting",to:copy).setting("revision",to:.number(String(saved.revision))),notes,nil) }
            let last = max(base,saved?.revision ?? base)
            guard last < maxRevision else { throw MeetingExportError.newerFormat }
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
        var result: (namespace: JSON, notes: JSON?) = (original,nil)
        do {
            try MeetingMetadataWriter(directory:meeting.folder,id:meeting.id).transaction(skippingUnchanged:true) { document in
                // Under the folder lock: meeting.json as it is now, number literals intact.
                let raw = (try? Data(contentsOf:url)).flatMap { try? JSONParser.parse($0) }
                let decided = try decide(raw,saved:baseline(raw?[baselineMember]))
                if let save = decided.save {
                    // Other Mac-local facts (untitledTitle) stay.
                    var baseline = document[baselineMember] as? [String:Any] ?? [:]
                    baseline.merge(save) { $1 }; document[baselineMember] = baseline
                }
                result = (decided.namespace,decided.notes)
            }
        } catch let error as POSIXError where [.EACCES,.EPERM,.EROFS].contains(error.code) {
            // Library folders are app-owned: an unwritable one is a fault, never an export
            // without its saved revision (that could reuse a revision for other content).
            throw MeetingExportError.libraryFolderNotWritable
        }
        return result
    }
    static let maxRevision = 9007199254740991
    /// What Mac changed, applied to another writer's meeting copy; unknown members stay:
    /// - the user's title and speaker names;
    /// - a Write down on Mac (#116 r2): its transcription state (status, reference, model, with
    ///   etaMinutes and error) once it differs from what import stored, the speakers it added
    ///   (whole entries, appended in Mac's order), and its writingDown facts.
    private static func edits(_ original: JSON, raw: JSON?, importedTranscript: [String:Any]) -> (copy: JSON, changed: Bool) {
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
        // Transcription state Mac produced (the words travel in the file's own transcript).
        // A missing or null transcript (not schema-valid, but seen) gains Mac's state too.
        let theirs = copy["transcript"].map { $0 == .null ? JSON.object([]) : $0 } ?? .object([])
        if let mine = raw["transcript"], mine.object != nil, theirs.object != nil {
            let keys = ["status","reference","model"]
            let stored = foundation(.object(keys.compactMap { key in mine[key].map { (key,$0) } }))
            if !(stored?.isEqual(importedTranscript) ?? false) {
                var transcript = theirs
                for key in keys where transcript[key] != mine[key] {
                    if let next = try? transcript.setting(key,to:mine[key]) { transcript = next }
                }
                set("transcript",transcript)
                for key in ["etaMinutes","error"] { if let value = raw[key] { set(key,value) } }
            }
        }
        // The writingDown facts of Mac's own Write down (import never stores recordingDetails):
        // Mac's known facts replace the other writer's attempt; its unknown facts stay.
        if let mine = raw["recordingDetails"]?["writingDown"], mine.object != nil,
           copy["recordingDetails"].map({ $0.object != nil || $0 == .null }) ?? true {
            let details = copy["recordingDetails"].flatMap { $0.object != nil ? $0 : nil } ?? .object([])
            var writing = details["writingDown"].flatMap { $0.object != nil ? $0 : nil } ?? .object([])
            for key in ["wallDurationMs","resumed","speechSegments","speakerSeparation","sourceSpansSeparated","recognitionFallback"] where writing[key] != mine[key] {
                if let next = try? writing.setting(key,to:mine[key]) { writing = next }
            }
            if let next = try? details.setting("writingDown",to:writing) { set("recordingDetails",next) }
        }
        // Speaker names the user set or cleared on Mac, matched by the original speaker id, and
        // the speakers Mac's Write down added.
        if copy["speakers"] == nil || copy["speakers"]?.array != nil {
            var speakers = copy["speakers"]?.array ?? []
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
            // A speaker id both writers use (a received file's track-original, D11): the label
            // Mac's Write down produced its words with replaces the other writer's (D48).
            for mine in raw["speakers"]?.array ?? [] {
                guard let id = mine["id"]?.string, let label = mine["label"], label.string != nil,
                      let index = speakers.firstIndex(where:{ $0["id"]?.string == id }), speakers[index]["label"] != label,
                      let next = try? speakers[index].setting("label",to:label) else { continue }
                speakers[index] = next; edited = true
            }
            let known = Set(speakers.compactMap { $0["id"]?.string })
            for mine in raw["speakers"]?.array ?? [] {
                guard let id = mine["id"]?.string, !known.contains(id) else { continue }
                speakers.append(mine); edited = true
            }
            if edited { set("speakers",.array(speakers)) }
        }
        return (copy,changed)
    }
    private static func foundation(_ value: JSON) -> NSDictionary? {
        (try? value.encoded()).flatMap { try? JSONSerialization.jsonObject(with:$0) as? NSDictionary }
    }
    /// Notes as a Foundation value, so equal notes compare equal whatever their number spelling.
    private static func noteValue(_ notes: JSON?) -> NSArray {
        guard let notes, notes.array?.isEmpty == false, let data = try? notes.encoded(),
              let value = try? JSONSerialization.jsonObject(with:data) as? NSArray else { return [] }
        return value
    }
    private static func digest(_ copy: JSON, notes: JSON?, body: String) throws -> String {
        var data = try copy.encoded()
        data.append(0)
        data.append(try JSONSerialization.data(withJSONObject:noteValue(notes),options:[.sortedKeys]))
        data.append(0)
        data.append(Data(body.utf8))
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    /// A namespace whose words the export read as damaged says so, whatever status is stored:
    /// the file can't carry words that weren't readable (Q14: the file's words are the truth).
    static func marking(_ namespace: JSON, damaged: Bool) throws -> JSON {
        guard damaged, let meeting = namespace["meeting"], var transcript = meeting["transcript"], transcript.object != nil,
              transcript["status"]?.string != "damaged" else { return namespace }
        transcript = try transcript.setting("status",to:.string("damaged"))
        return try namespace.setting("meeting",to:meeting.setting("transcript",to:transcript))
    }
    /// meeting.json notes verbatim (nil when absent or empty).
    static func localNotes(_ raw: JSON?) -> JSON? {
        guard let notes = raw?["notes"], let list = notes.array, !list.isEmpty else { return nil }
        return notes
    }
    /// #116 r3 (D13, Q13): the notes an export writes. While Mac's notes still equal what the
    /// import kept of the original file's notes (`LibraryImport.importedNotes`), the original
    /// note objects go back verbatim, unknown members included; otherwise Mac's own.
    static func exportNotes(local: JSON?, original: JSON?) -> (notes: JSON?, changed: Bool) {
        let imported = NSArray(array:LibraryImport.importedNotes(original))
        guard noteValue(local).isEqual(to:imported as! [Any]) else { return (local,true) }
        return (original?.array?.isEmpty == false ? original : nil,false)
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
