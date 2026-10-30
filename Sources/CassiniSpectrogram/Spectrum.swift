// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import Foundation

public enum SpectrogramError: Error { case sampleRate }

/// cassini-spectro-v1. The 24/48/96 kHz table uses the exact 2048/48000
/// window duration; 42.7 ms in the prose is rounded. No samples are resampled.
public struct SpectrogramParameters: Sendable {
    public let rate: Int
    public let size: Int
    public let hop: Int
    public var firstFrame: Int { (size + hop - 1) / hop - 1 }
    public static let bands = 32
    public static let edgesHz: [Double] = (0...bands).map { index in
        let low = 2595 * log10(1 + 80.0 / 700)
        let high = 2595 * log10(1 + 8000.0 / 700)
        return 700 * (pow(10,(low + (high-low)*Double(index)/Double(bands))/2595)-1)
    }
    public init(rate: Int = 48000) throws {
        guard (8000...192000).contains(rate) else { throw SpectrogramError.sampleRate }
        self.rate = rate
        hop = Int((Double(rate)*0.020).rounded(.toNearestOrEven))
        let required = (rate * 2048 + 47999) / 48000
        var length = 1
        while length < required { length <<= 1 }
        size = length
    }
    public func slot(frameEnd: Int64, startOffsetMs: Double) -> Int64 {
        Int64(floor((startOffsetMs + Double(frameEnd-Int64(size/2))/Double(rate)*1000)/20))
    }
}

/// Confined to the session's serial utility queue. FFT/window/weight workspaces
/// are reused; the input is the normalized mono PCM actually admitted to files.
/// A packed real FFT computes only the unique bins. Its factor-two output is
/// explicitly removed before the shared energy normalization.
public final class SpectrogramTransform {
    public let parameters: SpectrogramParameters
    private let setup: FFTSetup
    private let logSize: vDSP_Length
    private let scale: Double
    private let window: [Float]
    private let weights: [[(Int,Double)]]
    private var real: [Float], outputReal: [Float], outputImaginary: [Float], squared: [Float]

    public init(parameters: SpectrogramParameters) {
        self.parameters = parameters
        let size = parameters.size
        logSize = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(logSize,FFTRadix(kFFTRadix2))!
        scale = 2 / (Double(size) * (3*Double(size)/8))
        var hann = [Float](repeating:0,count:size)
        vDSP_hann_window(&hann,vDSP_Length(size),Int32(vDSP_HANN_DENORM))
        window = hann
        weights = (0..<SpectrogramParameters.bands).map { band in
            let low = SpectrogramParameters.edgesHz[band]*Double(size)/Double(parameters.rate)
            let high = SpectrogramParameters.edgesHz[band+1]*Double(size)/Double(parameters.rate)
            let first = Int(floor(low+0.5)), last = min(size/2,Int(ceil(high+0.5)))
            guard first <= last else { return [] }
            return (first...last).compactMap { bin in
                let weight = min(Double(bin)+0.5,high)-max(Double(bin)-0.5,low)
                return weight > 1e-9 ? (bin,weight) : nil
            }
        }
        real = [Float](repeating:0,count:size)
        outputReal = [Float](repeating:0,count:size/2); outputImaginary = outputReal
        squared = [Float](repeating:0,count:size/2+1)
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    public func powers(frame: [Float], startingAt first: Int = 0) -> [Double] {
        precondition(frame.count == parameters.size)
        precondition(frame.indices.contains(first))
        for index in frame.indices {
            let value = frame[(first+index) & (frame.count-1)]
            real[index] = value.isFinite ? max(-1,min(1,value)) : 0
        }
        return transformWorkspace()
    }

    // Track history is already finite and clipped. Copy its two contiguous
    // sections in C instead of sanitizing the same samples again at every hop.
    func powers(normalizedHistory source: UnsafeBufferPointer<Float>, startingAt first: Int) -> [Double] {
        precondition(source.count == parameters.size && source.indices.contains(first))
        real.withUnsafeMutableBufferPointer { destination in
            let tail = source.count-first
            destination.baseAddress!.update(from:source.baseAddress!+first,count:tail)
            if first > 0 { destination.baseAddress!.advanced(by:tail).update(from:source.baseAddress!,count:first) }
        }
        return transformWorkspace()
    }

    private func transformWorkspace() -> [Double] {
        var mean: Float = 0
        let count = vDSP_Length(parameters.size)
        vDSP_meanv(real,1,&mean,count); mean = -mean
        vDSP_vsadd(real,1,&mean,&real,1,count)
        vDSP_vmul(real,1,window,1,&real,1,count)
        let half = vDSP_Length(parameters.size/2)
        real.withUnsafeBufferPointer { input in
            outputReal.withUnsafeMutableBufferPointer { resultReal in
                outputImaginary.withUnsafeMutableBufferPointer { resultImaginary in
                    var output = DSPSplitComplex(realp:resultReal.baseAddress!,imagp:resultImaginary.baseAddress!)
                    input.baseAddress!.withMemoryRebound(to:DSPComplex.self,capacity:parameters.size/2) {
                        vDSP_ctoz($0,2,&output,1,half)
                    }
                    vDSP_fft_zrip(setup,&output,1,logSize,FFTDirection(FFT_FORWARD))
                    let dc = resultReal[0], nyquist = resultImaginary[0]
                    vDSP_zvmags(&output,1,&squared,1,half)
                    var quarter: Float = 0.25
                    vDSP_vsmul(squared,1,&quarter,&squared,1,half)
                    squared[0] = dc*dc*quarter
                    squared[parameters.size/2] = nyquist*nyquist*quarter
                }
            }
        }
        return weights.map { band in scale * band.reduce(0) { $0 + $1.1*Double(squared[$1.0]) } }
    }
}

/// The release belongs to the summed lane, never to individual tracks. A gap
/// resets it so a previous syllable cannot bridge missing audio.
public struct SpectrogramRelease: Sendable {
    private var previousSlot: Int64?
    private var held: [Double] = []
    public init() {}
    public mutating func reset() { previousSlot = nil; held = [] }
    public mutating func column(slot: Int64, powers: [Double]) -> [UInt8] {
        precondition(powers.count == SpectrogramParameters.bands)
        let decibels = powers.map(Self.decibels)
        if let previousSlot, slot == previousSlot + 1 {
            held = zip(decibels,held).map { max($0,$1-3) }
        } else { held = decibels }
        previousSlot = slot
        return held.map(Self.quantize)
    }
    public static func raw(powers: [Double]) -> [UInt8] { powers.map { quantize(decibels($0)) } }
    private static func decibels(_ power: Double) -> Double {
        if !power.isFinite { return power > 0 ? -20 : -120 }
        return 10*log10(max(power,1e-12))
    }
    private static func quantize(_ decibels: Double) -> UInt8 {
        UInt8((255*min(1,max(0,(decibels+80)/60))).rounded(.toNearestOrEven))
    }
}
