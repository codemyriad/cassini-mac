// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary

/// A transcript has speaker IDs, not source-track IDs. On resume, replace a
/// speaker's saved prefix only as far as every one of its tracks has reached.
/// Both halves use word starts, so a word crossing the frontier belongs to
/// exactly one half even when recognition ends beyond its segment boundary.
struct TranscriptProgress {
    struct Item { let word: LibraryTranscriptItem; let track: Int; let ordinal: Int }
    let previous: [LibraryTranscriptItem]
    let speakers: [String]
    private var through: [Int64]
    init(previous: [LibraryTranscriptItem], speakers: [String]) {
        self.previous = previous; self.speakers = speakers
        through = Array(repeating:Int64.min,count:speakers.count)
    }
    mutating func advance(track: Int, to time: Int64) { through[track] = max(through[track],time) }
    mutating func finish(track: Int) { through[track] = .max }
    func published(_ items: [Item], complete: Bool = false) -> [LibraryTranscriptItem] {
        var frontier: [String:Int64] = [:]
        for (index,speaker) in speakers.enumerated() { frontier[speaker] = min(frontier[speaker,default:.max],through[index]) }
        let oldSpeakers = Set(previous.map(\.speaker))
        let fresh = complete ? items : items.filter {
            !oldSpeakers.contains($0.word.speaker) || $0.word.startMs < frontier[$0.word.speaker,default:.min]
        }
        let tail: [Item] = complete ? [] : previous.enumerated().compactMap { index,word in
            guard word.startMs >= frontier[word.speaker,default:.min] else { return nil }
            return Item(word:word,track:speakers.firstIndex(of:word.speaker) ?? Int.max,ordinal:items.count + index)
        }
        return (fresh + tail).sorted {
            if $0.word.startMs != $1.word.startMs { return $0.word.startMs < $1.word.startMs }
            if $0.track != $1.track { return $0.track < $1.track }
            return $0.ordinal < $1.ordinal
        }.map(\.word)
    }
}
