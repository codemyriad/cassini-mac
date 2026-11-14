// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public enum Voiceprint {
    public static let model = "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"
    public static func normalized(_ values: [Float]) -> [Float]? {
        guard values.count == 512, values.allSatisfy(\.isFinite) else { return nil }
        let norm = Float(sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) }))
        guard norm.isFinite, norm > 0 else { return nil }
        return values.map { $0 / norm }
    }
}
public struct SavedVoice: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public let model: String
    public let dim: Int
    public var mean: [Float]
    public var count: Int
    public var seconds: Double
    public var meetings: [String]
    public let createdAt: Double
    public var updatedAt: Double
    public var stale: Bool { model != Voiceprint.model || dim != 512 || Voiceprint.normalized(mean) == nil }
    public var colourSlot: Int // Stable save-order slot; never recomputed after deletion.
    private enum CodingKeys: String, CodingKey { case id,name,model,dim,mean,count,seconds,meetings,createdAt,updatedAt,colourSlot }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
        model=try c.decode(String.self,forKey:.model);dim=try c.decode(Int.self,forKey:.dim)
        mean=try c.decode([Float].self,forKey:.mean);count=try c.decode(Int.self,forKey:.count)
        seconds=try c.decode(Double.self,forKey:.seconds);meetings=try c.decode([String].self,forKey:.meetings)
        createdAt=try c.decode(Double.self,forKey:.createdAt);updatedAt=try c.decode(Double.self,forKey:.updatedAt)
        colourSlot=try c.decodeIfPresent(Int.self,forKey:.colourSlot) ?? -1
    }
    init(id:String,name:String,model:String,dim:Int,mean:[Float],count:Int,seconds:Double,meetings:[String],createdAt:Double,updatedAt:Double,colourSlot:Int) {
        self.id=id;self.name=name;self.model=model;self.dim=dim;self.mean=mean;self.count=count;self.seconds=seconds
        self.meetings=meetings;self.createdAt=createdAt;self.updatedAt=updatedAt;self.colourSlot=colourSlot
    }
}
public struct VoiceClip: Codable, Sendable, Equatable {
    public let meeting: String
    public let speaker: String
    public let startMs: Int64
    public let endMs: Int64
    public init(meeting: String, speaker: String, startMs: Int64, endMs: Int64) {
        self.meeting=meeting; self.speaker=speaker; self.startMs=startMs; self.endMs=endMs
    }
}
public struct SavedVoicesSnapshot: Sendable {
    public let generation: Int64
    public let voices: [SavedVoice]
    public let clips: [String:VoiceClip]
    public let readOnly: Bool
}
public enum SavedVoicesError: Error { case newerVersion, invalidName, invalidPrint, changedGeneration, unsafeStorage, missingVoice }

/// One atomic document owns profiles and sample references. No audio or biometric
/// data is written to the Library. flock also serializes separate app processes.
public actor SavedVoicesStore {
    private struct Document: Codable {
        var version=1
        var generation:Int64=0
        var voices: [SavedVoice]=[]
        var clips: [String:VoiceClip]=[:]
        var nextColourSlot=0
        init() {}
        enum CodingKeys:String,CodingKey { case version,generation,voices,clips,nextColourSlot }
        init(from decoder:Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            version=try c.decode(Int.self,forKey:.version);generation=try c.decode(Int64.self,forKey:.generation)
            voices=try c.decode([SavedVoice].self,forKey:.voices)
            clips=try c.decodeIfPresent([String:VoiceClip].self,forKey:.clips) ?? [:]
            for index in voices.indices where voices[index].colourSlot < 0 { voices[index].colourSlot=index }
            nextColourSlot=max(try c.decodeIfPresent(Int.self,forKey:.nextColourSlot) ?? 0,(voices.map(\.colourSlot).max() ?? -1)+1)
        }
    }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Cassini/voices",isDirectory:true)
    }
    public static func validName(_ name:String) -> Bool { SpeakerEdits.validName(name) && SpeakerEdits.normalizedName(name) != nil }
    private let directory: URL
    public init(directory: URL = SavedVoicesStore.defaultDirectory) { self.directory=directory }
    private func transaction<T>(_ body: (inout Document) throws -> T, write: Bool) throws -> T {
        let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw SavedVoicesError.unsafeStorage }
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let fd=open(directory.appendingPathComponent(".lock").path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw SavedVoicesError.unsafeStorage }
        defer { flock(fd,LOCK_UN); close(fd) }
        guard flock(fd,LOCK_EX) == 0 else { throw SavedVoicesError.unsafeStorage }
        let file=directory.appendingPathComponent("people.json")
        var document=Document()
        if fm.fileExists(atPath:file.path) {
            let attributes=try fm.attributesOfItem(atPath:file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16 << 20 else { throw SavedVoicesError.unsafeStorage }
            let data=try Data(contentsOf:file)
            let version=(try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["version"] as? Int
            if let version, version > 1 {
                guard !write else { throw SavedVoicesError.newerVersion }
                // Preserve unknown formats byte-for-byte; callers display read-only state.
                var newer=documentWithNewerVersion(version)
                return try body(&newer)
            }
            do { document=try JSONDecoder().decode(Document.self,from:data) }
            catch {
                try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                try fm.moveItem(at:file,to:directory.appendingPathComponent("people.json.corrupt-\(UUID().uuidString)"))
            }
        }
        let result=try body(&document)
        if write || !fm.fileExists(atPath:file.path) {
            let data=try JSONEncoder().encode(document)
            let staged=directory.appendingPathComponent(".people-"+UUID().uuidString)
            let output=open(staged.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            let handle=FileHandle(fileDescriptor:output,closeOnDealloc:true)
            defer { try? handle.close(); try? fm.removeItem(at:staged) }
            try handle.write(contentsOf:data);try handle.synchronize()
            guard Darwin.rename(staged.path,file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        }
        return result
    }
    private func documentWithNewerVersion(_ version: Int) -> Document { var d=Document(); d.version=version; return d }
    public func snapshot() throws -> SavedVoicesSnapshot {
        try transaction({ d in
            let sorted=d.voices.sorted {
                if $0.meetings.count != $1.meetings.count { return $0.meetings.count > $1.meetings.count }
                if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return .init(generation:d.generation,voices:sorted,clips:d.clips,readOnly:d.version > 1)
        },write:false)
    }
    public func rename(_ id: String, to name: String) throws {
        guard Self.validName(name) else { throw SavedVoicesError.invalidName }
        try transaction({ d in
            guard let i=d.voices.firstIndex(where:{$0.id == id}) else { throw SavedVoicesError.missingVoice }
            d.voices[i].name=SpeakerEdits.normalizedName(name)!; d.voices[i].updatedAt=Date().timeIntervalSince1970
        },write:true)
    }
    @discardableResult public func enroll(name: String, embedding: [Float], seconds: Double, generation: Int64,
                                         into id: String? = nil, clip: VoiceClip? = nil) throws -> String {
        guard Self.validName(name) else { throw SavedVoicesError.invalidName }
        guard let print=Voiceprint.normalized(embedding), seconds.isFinite, seconds >= 4, seconds <= 45 else { throw SavedVoicesError.invalidPrint }
        return try transaction({ d in
            guard d.generation == generation else { throw SavedVoicesError.changedGeneration }
            let now=Date().timeIntervalSince1970
            let voiceID: String
            if let id {
                guard let i=d.voices.firstIndex(where:{$0.id == id}), !d.voices[i].stale else { throw SavedVoicesError.missingVoice }
                let weight=Float(min(d.voices[i].count,20))
                guard let mean=Voiceprint.normalized(zip(d.voices[i].mean,print).map { $0 * weight + $1 }) else { throw SavedVoicesError.invalidPrint }
                d.voices[i].mean=mean; d.voices[i].count += 1; d.voices[i].seconds += seconds; d.voices[i].updatedAt=now
                if let clip, !d.voices[i].meetings.contains(clip.meeting) { d.voices[i].meetings.append(clip.meeting) }
                voiceID=id
            } else {
                voiceID="voice_" + UUID().uuidString
                d.voices.append(.init(id:voiceID,name:SpeakerEdits.normalizedName(name)!,model:Voiceprint.model,dim:512,mean:print,
                    count:1,seconds:seconds,meetings:clip.map { [$0.meeting] } ?? [],createdAt:now,updatedAt:now,colourSlot:d.nextColourSlot))
                d.nextColourSlot += 1
            }
            if let clip { d.clips[voiceID]=clip }
            return voiceID
        },write:true)
    }
    public func forget(_ id: String) throws {
        try transaction({ d in d.voices.removeAll { $0.id == id }; d.clips[id]=nil; d.generation += 1 },write:true)
    }
    public func forgetEveryone() throws {
        // Persist the tombstone before a job holding an old snapshot can commit.
        try transaction({ d in d.generation += 1; d.voices=[]; d.clips=[:] },write:true)
    }
}
