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
        guard nowMs.isFinite, nowMs >= 0 else { return tracks }
        guard chosenAt == nil || nowMs-chosenAt! >= 1000 else { return tracks }
        chosenAt = nowMs
        var ranked: [(id:Int,level:Float)] = []
        for (id,level) in levels { ranked.append((id,level.isFinite ? max(Float(0),level) : 0)) }
        ranked.sort {
            if $0.level == $1.level { return $0.id < $1.id }
            return $0.level > $1.level
        }
        tracks = Set(ranked.prefix(3).map(\.id))
        return tracks
    }
}
