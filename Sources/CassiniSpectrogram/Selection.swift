// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One instance per session lane. The caller supplies active tracks' existing
/// 100 ms AC levels; unselected tracks still retain their sample history.
public struct SpectrogramSelection {
    public private(set) var tracks: Set<Int> = []
    private var chosenAt: Double?
    public init() {}
    public mutating func reset() { tracks = []; chosenAt = nil }
    @discardableResult public mutating func choose(levels: [Int:Float], nowMs: Double) -> Set<Int> {
        precondition(levels.keys.allSatisfy { (0..<64).contains($0) })
        guard nowMs.isFinite, nowMs >= 0, !levels.isEmpty else { return tracks }
        let due = chosenAt == nil || nowMs-chosenAt! >= 1000
        let vacant = !due && tracks.count < 3 && levels.keys.contains { !tracks.contains($0) }
        guard due || vacant else { return tracks }
        if due { chosenAt = nowMs }
        var ranked: [(id:Int,level:Float)] = []
        for (id,level) in levels { ranked.append((id,level.isFinite ? max(Float(0),level) : 0)) }
        ranked.sort {
            if $0.level == $1.level { return $0.id < $1.id }
            return $0.level > $1.level
        }
        if due { tracks = Set(ranked.prefix(3).map(\.id)) }
        else { tracks.formUnion(ranked.filter { !tracks.contains($0.id) }.prefix(3-tracks.count).map(\.id)) }
        return tracks
    }
}
