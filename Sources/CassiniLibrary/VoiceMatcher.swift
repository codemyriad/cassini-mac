// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum VoiceMatcher {
    public struct Print: Sendable {
        public let speaker:String
        public let embedding:[Float]
        public init(speaker:String,embedding:[Float]) { self.speaker=speaker; self.embedding=embedding }
    }
    public struct Match: Sendable, Equatable {
        public let speaker:String
        public let voiceID:String
        public let score:Float
        public let automatic:Bool
    }
    public static func cosine(_ a:[Float],_ b:[Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return nil }
        return Float(zip(a,b).reduce(0.0) { $0+Double($1.0)*Double($1.1) })
    }
    public static func ranked(_ embedding:[Float],voices:[SavedVoice]) -> [(voice:SavedVoice,score:Float?)] {
        voices.map { ($0,$0.stale ? nil:cosine(embedding,$0.mean)) }.sorted {
            if $0.1 != $1.1 { return ($0.1 ?? -.infinity) > ($1.1 ?? -.infinity) }
            return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
        }
    }
    /// Stable greedy assignment; a rival can be a voice for this speaker or
    /// another speaker for this voice. User names are filtered by the caller.
    public static func assign(_ prints:[Print],voices:[SavedVoice],rejected:Set<String> = []) -> [Match] {
        struct Candidate { let speaker:String;let voice:String;let score:Float;let ordinal:Int }
        var candidates:[Candidate]=[]
        for print in prints {
            for voice in voices where !voice.stale && !rejected.contains(print.speaker+"\u{1f}"+voice.id) {
                if let score=cosine(print.embedding,voice.mean) { candidates.append(.init(speaker:print.speaker,voice:voice.id,score:score,ordinal:candidates.count)) }
            }
        }
        candidates.sort { $0.score == $1.score ? $0.ordinal < $1.ordinal:$0.score > $1.score }
        // Precompute the two best scores per side, avoiding a scan per pair.
        var speakerScores:[String:[Float]]=[:],voiceScores:[String:[Float]]=[:]
        for c in candidates {
            if speakerScores[c.speaker,default:[]].count < 2 { speakerScores[c.speaker,default:[]].append(c.score) }
            if voiceScores[c.voice,default:[]].count < 2 { voiceScores[c.voice,default:[]].append(c.score) }
        }
        var speakers=Set<String>(),usedVoices=Set<String>(),result:[Match]=[]
        for c in candidates where c.score >= 0.50 && !speakers.contains(c.speaker) && !usedVoices.contains(c.voice) {
            func rival(_ scores:[Float]) -> Float { scores.first == c.score ? (scores.dropFirst().first ?? -.infinity):(scores.first ?? -.infinity) }
            let next=max(rival(speakerScores[c.speaker] ?? []),rival(voiceScores[c.voice] ?? []))
            result.append(.init(speaker:c.speaker,voiceID:c.voice,score:c.score,automatic:c.score >= 0.72 && c.score-next >= 0.08))
            speakers.insert(c.speaker);usedVoices.insert(c.voice)
        }
        return result
    }
}
