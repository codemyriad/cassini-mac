// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct SpectrogramPowerFrame: Sendable {
    public let sampleEnd: Int64
    public let centreMs: Double
    public let slot: Int64
    public let powers: [Double]
}

/// A fixed N-sample history on one track's sample clock. All calls, including
/// calls to a shared transform, belong to the session's serial utility queue.
public final class SpectrogramTrack {
    public let parameters: SpectrogramParameters
    public let startOffsetMs: Double
    public private(set) var positionFrames: Int64 = 0
    public private(set) var analyzedFrames: UInt64 = 0
    public private(set) var latestLevel: Float = 0
    public private(set) var latestLevelAtFrame: Int64 = 0
    private let transform: SpectrogramTransform
    private var history: [Float]
    private var write = 0, valid = 0
    private var nextEnd: Int64
    private var levelCount = 0
    private var levelSum = 0.0, levelMin = Double.infinity, levelMax = -Double.infinity

    public init(parameters: SpectrogramParameters, startOffsetMs: Double, transform: SpectrogramTransform) {
        precondition(startOffsetMs.isFinite && startOffsetMs >= 0)
        precondition(parameters.rate == transform.parameters.rate)
        self.parameters = parameters; self.startOffsetMs = startOffsetMs; self.transform = transform
        history = [Float](repeating:0,count:parameters.size)
        nextEnd = Int64((parameters.firstFrame+1)*parameters.hop)
    }

    public func skip(frames: Int64) {
        precondition(frames >= 0 && frames <= Int64.max-positionFrames)
        guard frames > 0 else { return }
        positionFrames += frames; write = 0; valid = 0
        nextEnd = (positionFrames/Int64(parameters.hop)+1)*Int64(parameters.hop)
        resetLevel(); latestLevel = 0; latestLevelAtFrame = positionFrames
    }

    public func append(_ samples: [Float], atFrame: Int64, analyze: Bool = true, emit: (SpectrogramPowerFrame) -> Void) {
        samples.withUnsafeBufferPointer { append($0,atFrame:atFrame,analyze:analyze,emit:emit) }
    }
    /// Overlap is trimmed; missing input advances time and invalidates history.
    /// Unselected tracks retain history and AC level without performing FFTs.
    public func append(_ samples: UnsafeBufferPointer<Float>, atFrame: Int64, analyze: Bool = true, emit: (SpectrogramPowerFrame) -> Void) {
        precondition(atFrame >= 0)
        if atFrame > positionFrames { skip(frames:atFrame-positionFrames) }
        let trim = Int(min(Int64(samples.count),positionFrames-atFrame))
        for index in trim..<samples.count {
            let value = samples[index].isFinite ? max(-1,min(1,samples[index])) : 0
            history[write] = value; write = (write+1) & (parameters.size-1)
            valid = min(parameters.size,valid+1); positionFrames += 1
            levelSum += Double(value); levelMin = min(levelMin,Double(value)); levelMax = max(levelMax,Double(value))
            levelCount += 1
            if levelCount == max(1,parameters.rate/10) {
                let mean = levelSum/Double(levelCount)
                latestLevel = Float(min(1,max(abs(levelMin-mean),abs(levelMax-mean))))
                latestLevelAtFrame = positionFrames; resetLevel()
            }
            guard positionFrames == nextEnd else { continue }
            nextEnd += Int64(parameters.hop)
            guard analyze, valid == parameters.size else { continue }
            let powers = transform.powers(frame:history,startingAt:write)
            analyzedFrames += 1
            emit(.init(sampleEnd:positionFrames,
                centreMs:startOffsetMs + Double(positionFrames-Int64(parameters.size/2))/Double(parameters.rate)*1000,
                slot:parameters.slot(frameEnd:positionFrames,startOffsetMs:startOffsetMs),powers:powers))
        }
    }
    private func resetLevel() {
        levelCount = 0; levelSum = 0; levelMin = .infinity; levelMax = -.infinity
    }
}
