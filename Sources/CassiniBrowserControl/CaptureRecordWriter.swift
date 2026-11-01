// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniLibrary
import CassiniRecording

/// D52.1 R65/R69: the portable `recordingDetails.captureRecord` (version 1) in
/// meeting.json, written after the capture closes. Sources merge by
/// sourceTrackId and tracks by id, keeping unknown fields; captureExpected is
/// replaced; a record of another version is never downgraded. No paths, URLs or
/// device identities are written.
public enum CaptureRecordWriter {
    static let trackFields: Set<String> = ["id","kind","label","sourceTrackId","frames","sampleRate","channels","startOffsetMs","endOffsetMs",
                                           "gapFrames","droppedFrames","problemKind","captureOutcome","receivedFrames","gaps"]
    public static func record(_ manifest: RecordingManifest) throws -> [String:Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let session = try JSONSerialization.jsonObject(with:encoder.encode(manifest)) as? [String:Any] ?? [:]
        var record: [String:Any] = ["version":1]
        record["tracks"] = (session["tracks"] as? [[String:Any]] ?? []).map { $0.filter { trackFields.contains($0.key) } }
        record["events"] = session["events"] as? [[String:Any]] ?? []
        if let outcome = session["captureOutcome"] as? [String:Any] {
            record["sources"] = outcome["sources"] as? [[String:Any]] ?? []
            if let unreported = outcome["unreportedSourceCount"] { record["unreportedSourceCount"] = unreported }
        } else { record["sources"] = [[String:Any]]() }
        if let kind = session["problemKind"] { record["problemKind"] = kind }
        return record
    }
    /// Merge `fresh` into a stored record. Returns nil when the stored record must be left untouched.
    public static func merge(_ stored: [String:Any]?, _ fresh: [String:Any]) -> [String:Any]? {
        guard let stored else { return fresh }
        guard (stored["version"] as? Int) == 1 else { return nil }
        func rows(_ key: String, id: String) -> [[String:Any]] {
            var result = stored[key] as? [[String:Any]] ?? []
            for row in fresh[key] as? [[String:Any]] ?? [] {
                guard let value = row[id] as? String else { continue }
                if let index = result.firstIndex(where:{ $0[id] as? String == value }) {
                    var merged = result[index].merging(row) { _, new in new }
                    if key == "sources", row["captureExpected"] == nil { merged.removeValue(forKey:"captureExpected") }
                    result[index] = merged
                } else { result.append(row) }
            }
            return result
        }
        var merged = stored
        merged["sources"] = rows("sources",id:"sourceTrackId"); merged["tracks"] = rows("tracks",id:"id")
        merged["events"] = fresh["events"]
        for key in ["problemKind","unreportedSourceCount"] { merged[key] = fresh[key] }
        return merged
    }
    public static func write(_ manifest: RecordingManifest, directory: URL) throws {
        let fresh = try record(manifest)
        try MeetingMetadataWriter(directory:directory,id:manifest.id).transaction(skippingUnchanged:true) { metadata in
            var details = metadata["recordingDetails"] as? [String:Any] ?? [:]
            guard let merged = merge(details["captureRecord"] as? [String:Any],fresh) else { return }
            details["captureRecord"] = merged
            metadata["recordingDetails"] = details
        }
    }
}
