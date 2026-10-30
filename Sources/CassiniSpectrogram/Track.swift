// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Accelerate

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
    private var levelScratch: [Double]
    private var write = 0, valid = 0
    private var nextEnd: Int64
    private var levelCount = 0
    private var levelSum = 0.0, levelMin = Double.infinity, levelMax = -Double.infinity

    public init(parameters: SpectrogramParameters, startOffsetMs: Double, transform: SpectrogramTransform) {
        precondition(startOffsetMs.isFinite && startOffsetMs >= 0)
        precondition(parameters.rate == transform.parameters.rate)
        self.parameters = parameters; self.startOffsetMs = startOffsetMs; self.transform = transform
        history = [Float](repeating:0,count:parameters.size)
        levelScratch = [Double](repeating:0,count:parameters.hop)
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
        appendCore(samples,atFrame:atFrame,analyze:analyze,normalized:false,emit:emit)
    }
    // Only the S16 conversion path calls this: its finite [-1,1] invariant is
    // guaranteed by the representation, including stereo averaging.
    func appendNormalized(_ samples: UnsafeBufferPointer<Float>, atFrame: Int64, analyze: Bool, emit: (SpectrogramPowerFrame) -> Void) {
        appendCore(samples,atFrame:atFrame,analyze:analyze,normalized:true,emit:emit)
    }
    private func appendCore(_ samples: UnsafeBufferPointer<Float>, atFrame: Int64, analyze: Bool, normalized: Bool, emit: (SpectrogramPowerFrame) -> Void) {
        precondition(atFrame >= 0)
        if atFrame > positionFrames { skip(frames:atFrame-positionFrames) }
        let trim = Int(min(Int64(samples.count),positionFrames-atFrame))
        if !normalized {
            let clean = samples.map { $0.isFinite ? max(-1,min(1,$0)) : 0 }
            clean.withUnsafeBufferPointer { appendCore($0,atFrame:atFrame,analyze:analyze,normalized:true,emit:emit) }
            return
        }
        // Copy contiguous runs up to the next history wrap, FFT hop or100ms
        // AC boundary. Accelerate retains the same Double sum/min/max rule;
        // per-sample Swift history/position checks disappear from the IO path.
        history.withUnsafeMutableBufferPointer { history in
            levelScratch.withUnsafeMutableBufferPointer { scratch in
                var index = trim
                let levelWindow = max(1,parameters.rate/10)
                while index < samples.count {
                    let count = min(parameters.hop,samples.count-index,parameters.size-write,
                                    Int(nextEnd-positionFrames),levelWindow-levelCount)
                    let input = samples.baseAddress!+index
                    history.baseAddress!.advanced(by:write).update(from:input,count:count)
                    let length = vDSP_Length(count)
                    vDSP_vspdp(input,1,scratch.baseAddress!,1,length)
                    var sum = 0.0, low: Float = 0, high: Float = 0
                    vDSP_sveD(scratch.baseAddress!,1,&sum,length)
                    vDSP_minv(input,1,&low,length); vDSP_maxv(input,1,&high,length)
                    levelSum += sum; levelMin = min(levelMin,Double(low)); levelMax = max(levelMax,Double(high))
                    index += count; write = (write+count) & (parameters.size-1)
                    valid = min(parameters.size,valid+count); positionFrames += Int64(count); levelCount += count
                    if levelCount == levelWindow {
                        let mean = levelSum/Double(levelCount)
                        latestLevel = Float(min(1,max(abs(levelMin-mean),abs(levelMax-mean))))
                        latestLevelAtFrame = positionFrames; resetLevel()
                    }
                    guard positionFrames == nextEnd else { continue }
                    nextEnd += Int64(parameters.hop)
                    guard analyze, valid == parameters.size else { continue }
                    let powers = transform.powers(normalizedHistory:UnsafeBufferPointer(history),startingAt:write)
                    analyzedFrames += 1
                    emit(.init(sampleEnd:positionFrames,
                        centreMs:startOffsetMs + Double(positionFrames-Int64(parameters.size/2))/Double(parameters.rate)*1000,
                        slot:parameters.slot(frameEnd:positionFrames,startOffsetMs:startOffsetMs),powers:powers))
                }
            }
        }
    }

    private func resetLevel() {
        levelCount = 0; levelSum = 0; levelMin = .infinity; levelMax = -.infinity
    }
}
