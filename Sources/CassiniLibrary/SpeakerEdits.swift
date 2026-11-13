// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// D24/UX16: edits only meeting.json. Stored transcript IDs and audio never change.
public enum SpeakerEdits {
    public enum Edit: Sendable {
        case name(speaker:String,value:String)
        case merge(from:String,into:String)
        case undoMerge
    }
    public static func normalizedName(_ value:String) -> String? {
        let name=value.trimmingCharacters(in:.whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    public static func validName(_ value:String) -> Bool {
        let name=normalizedName(value) ?? ""
        return name.unicodeScalars.count <= 64 && !name.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }
    }
    /// Fresh validation runs inside the metadata transaction's directory lock.
    /// The UI supplies security-scoped Library roots and serializes against move/Trash/Quit.
    public static func apply(_ edit:Edit,to meeting:LibraryMeeting,roots:[URL],scanner:LibraryScanner? = nil) throws {
        let directory=meeting.folder
        let parent=try physicalURL(directory.deletingLastPathComponent())
        guard let info=try pathInfo(directory),info.st_mode & S_IFMT == S_IFDIR,
              roots.contains(where:{ (try? physicalURL($0)) == parent }) else {throw POSIXError(.EACCES)}
        let scanner=scanner ?? LibraryScanner(root:directory.deletingLastPathComponent())
        try MeetingMetadataWriter(directory:directory,id:meeting.id).transaction(skippingUnchanged:true) { document in
            guard let fresh=scanner.meeting(at:directory),fresh.id==meeting.id,
                  fresh.metadataRevision != nil,!fresh.metadataReadOnly,fresh.state.lifecycle == .saved,
                  ![.queued,.running].contains(fresh.state.transcript) else {throw POSIXError(.EPERM)}
            switch edit {
            case .name(let id,let value):
                guard validName(value),let speaker=fresh.speakers.first(where:{$0.id==id}) else {throw POSIXError(.EINVAL)}
                var speakers=document["speakers"] as? [[String:Any]] ?? []
                let index=speakers.firstIndex(where:{$0["id"] as? String == id})
                var entry=index.map {speakers[$0]} ?? ["id":id,"colourIndex":speaker.colourIndex]
                let name=normalizedName(value)
                entry["name"]=name.map {$0 as Any} ?? NSNull()
                entry["provenance"]=name == nil ? "unnamed" : "user"
                if name == nil {entry["nameCleared"]=true}
                else {entry.removeValue(forKey:"nameCleared")}
                // D48: a producer's original label survives Save/Clear and Merge/Undo.
                if let index {speakers[index]=entry} else {speakers.append(entry)}
                document["speakers"]=speakers
            case .merge(let from,let into):
                let visible=Set(fresh.speakers.map(\.id))
                guard from != into,visible.contains(from),visible.contains(into) else {throw POSIXError(.EINVAL)}
                var history=document["speakerMerges"] as? [[String:Any]] ?? []
                history.append(["from":from,"into":into]);document["speakerMerges"]=history
            case .undoMerge:
                guard var history=document["speakerMerges"] as? [[String:Any]],!history.isEmpty else {return}
                history.removeLast();document["speakerMerges"]=history
            }
        }
    }
    public static func talkTime(_ meeting:LibraryMeeting,speaker:String) -> Int64 {
        MeetingPresentation.spans(meeting.transcriptItems.filter {$0.speaker==speaker}).reduce(0) {$0+$1.end-$1.start}
    }
    /// The longest chronological turn, capped at ten seconds; ties keep first appearance.
    public static func sample(_ meeting:LibraryMeeting,speaker:String) -> Range<Int64>? {
        let turns=SpeakerTurn.grouping(meeting.transcriptItems.filter {$0.endMs>$0.startMs}).filter {$0.speaker==speaker && $0.endMs>$0.startMs}
        var longest:SpeakerTurn?
        for turn in turns where longest == nil || turn.endMs-turn.startMs > longest!.endMs-longest!.startMs {longest=turn}
        guard let turn=longest else {return nil}
        return turn.startMs..<min(turn.endMs,turn.startMs+10_000)
    }
    /// Bounded words from the actual sample, in chronological order. Display only;
    /// the original sidecar, timing and speaker identity remain untouched.
    public static func sampleQuote(_ meeting: LibraryMeeting, speaker: String, range: Range<Int64>) -> String? {
        guard !range.isEmpty else { return nil }
        let words = meeting.transcriptItems.enumerated().filter {
            $0.element.speaker == speaker && $0.element.endMs > range.lowerBound && $0.element.startMs < range.upperBound
        }.sorted {
            $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
        }
        var quote = ""
        for (_, word) in words where !word.text.isEmpty {
            if !quote.isEmpty { quote += " " }
            quote += word.text.prefix(max(0, 241 - quote.count))
            if quote.count > 240 { return String(quote.prefix(240)) + "…" }
        }
        return quote.isEmpty ? nil : quote
    }

}
