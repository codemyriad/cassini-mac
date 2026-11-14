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
    public var model: String
    public var dim: Int
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
public enum SavedVoicesError: Error { case newerVersion, invalidName, invalidPrint, unavailable, changedGeneration, unsafeStorage, missingVoice }

/// One atomic document owns profiles and sample references. No audio or biometric
/// data is written to the Library. flock also serializes separate app processes.
public actor SavedVoicesStore {
    private struct Contribution:Codable { let voiceID:String;let embedding:[Float];let clip:VoiceClip }
    private struct Document: Codable {
        var version=1
        var generation:Int64=0
        var voices: [SavedVoice]=[]
        var clips: [String:VoiceClip]=[:]
        var nextColourSlot=0
        var contributions:[String:Contribution]=[:]
        init() {}
        enum CodingKeys:String,CodingKey { case version,generation,voices,clips,nextColourSlot,contributions }
        init(from decoder:Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            version=try c.decode(Int.self,forKey:.version);generation=try c.decode(Int64.self,forKey:.generation)
            voices=try c.decode([SavedVoice].self,forKey:.voices)
            contributions=try c.decodeIfPresent([String:Contribution].self,forKey:.contributions) ?? [:]
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
            let key=clip.map { $0.meeting+"\u{1f}"+$0.speaker }
            var target=id
            if let key, let previous=d.contributions[key] {
                let prior=d.voices.first { $0.id == previous.voiceID }
                if (target == previous.voiceID || target == nil && prior?.name == SpeakerEdits.normalizedName(name)), previous.embedding == print {
                    return previous.voiceID // Retrying Save never counts a clip twice.
                }
                if target == nil, prior?.name == SpeakerEdits.normalizedName(name) { target=previous.voiceID }
                Self.removeContribution(key,from:&d)
                if let targetID=target, !d.voices.contains(where:{$0.id == targetID}) { target=nil }
            }
            let voiceID: String
            if let id=target {
                guard let i=d.voices.firstIndex(where:{$0.id == id}) else { throw SavedVoicesError.missingVoice }
                if d.voices[i].stale {
                    d.voices[i].model=Voiceprint.model; d.voices[i].dim=512;d.voices[i].mean=print
                    d.voices[i].count=0;d.voices[i].seconds=0;d.voices[i].meetings=[]
                    d.contributions=d.contributions.filter { $0.value.voiceID != id }
                }
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
            if let clip, let key {
                d.clips[voiceID]=clip
                d.contributions[key] = .init(voiceID:voiceID,embedding:print,clip:clip)
            }
            return voiceID
        },write:true)
    }
    private static func removeContribution(_ key:String,from d:inout Document) {
        guard let previous=d.contributions.removeValue(forKey:key),let i=d.voices.firstIndex(where:{$0.id == previous.voiceID}) else { return }
        if d.voices[i].count <= 1 { d.voices.remove(at:i);d.clips[previous.voiceID]=nil;return }
        let voice=d.voices[i], e=previous.embedding
        if let dot=VoiceMatcher.cosine(voice.mean,e) {
            let w=Double(min(voice.count-1,20)), v=Double(dot)
            let length=Float(v+sqrt(max(0,v*v-1+w*w)))
            if let mean=Voiceprint.normalized(zip(voice.mean,e).map { $0*length-$1 }) { d.voices[i].mean=mean }
        }
        d.voices[i].count -= 1 // Confirmed seconds are a lifetime total (D25).
        let remaining=d.contributions.values.filter { $0.voiceID == previous.voiceID }
        if !remaining.contains(where:{$0.clip.meeting == previous.clip.meeting}) { d.voices[i].meetings.removeAll { $0 == previous.clip.meeting } }
        d.clips[previous.voiceID]=remaining.first?.clip
    }
    public func unenroll(meeting:String,speakers:Set<String>) throws {
        try transaction({ d in
            for speaker in speakers { Self.removeContribution(meeting+"\u{1f}"+speaker,from:&d) }
        },write:true)
    }
    public func forget(_ id: String) throws {
        try transaction({ d in d.voices.removeAll { $0.id == id }; d.clips[id]=nil; d.contributions=d.contributions.filter { $0.value.voiceID != id }; d.generation += 1 },write:true)
    }
    public func forgetEveryone() throws {
        // Persist the tombstone before a job holding an old snapshot can commit.
        try transaction({ d in d.generation += 1; d.voices=[]; d.clips=[:];d.contributions=[:] },write:true)
    }
}
