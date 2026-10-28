// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniSherpaBridge
import CassiniWhistle
import Darwin

public struct ParakeetToken: Sendable {
    public let text: String
    public let timestamp: Float
    public let duration: Float
    public init(text: String, timestamp: Float, duration: Float) { self.text = text; self.timestamp = timestamp; self.duration = duration }
}
public enum ParakeetWords {
    /// D16: keep the engine's float32 values, promote before arithmetic, and
    /// round half away from zero. Punctuation never extends a spoken word.
    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }
    public static func decode(_ tokens: [ParakeetToken]) throws -> [WhistleTranscript.Word] {
        struct Word { var text: String; let startMs: Int64; var endMs: Int64? }
        var current: Word?, output: [WhistleTranscript.Word] = []
        func flush() throws {
            guard let word = current, !word.text.isEmpty else { return }
            let end = word.endMs ?? word.startMs
            guard end >= word.startMs else { throw ParakeetFailure.invalidTokens }
            output.append(.init(word:word.text,start:Double(word.startMs)/1000,end:Double(end)/1000,probability:1))
        }
        for token in tokens {
            let time = Double(token.timestamp), duration = Double(token.duration)
            guard time.isFinite, duration.isFinite, time >= 0, duration >= 0, time + duration <= 31 else { throw ParakeetFailure.invalidTokens }
            let startMs = Int64((time * 1000).rounded(.toNearestOrAwayFromZero))
            let endMs = Int64(((time + duration) * 1000).rounded(.toNearestOrAwayFromZero))
            let begins = token.text.hasPrefix("▁") || token.text.hasPrefix(" ")
            let piece = begins ? String(token.text.dropFirst()) : token.text
            if begins || current == nil { try flush(); current = Word(text:"",startMs:startMs) }
            current!.text += piece
            if piece.unicodeScalars.contains(where:{ isLetterOrNumber($0) }) {
                current!.endMs = max(current!.endMs ?? Int64.min,endMs)
            }
        }
        try flush(); return output
    }
}
/// Instantiated only in the Parakeet worker/golden process, never Cassini's UI
/// and never a process that has loaded the Whistle recognizer.
public final class ParakeetEngine {
    private let handle: OpaquePointer
    private let operations = NSLock()
    public init(assets: ParakeetAssets) throws {
        guard let value = getenv("ORT_DISABLE_TELEMETRY"), String(cString:value) == "1" else { throw ParakeetFailure.privacy }
        var error = [CChar](repeating:0,count:4096)
        let handle = assets.library.path.withCString { library in assets.ort.path.withCString { ort in assets.model.path.withCString { model in
            cassini_sherpa_create(library,ort,model,&error,error.count)
        } } }
        guard let handle else { throw ParakeetFailure.runtime(String(decoding:error.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)) }
        self.handle = handle
    }
    deinit { cassini_sherpa_destroy(handle) }
    public func transcribe(samples: [Float]) throws -> WhistleTranscript {
        guard !samples.isEmpty, samples.count <= 480000, samples.allSatisfy(\.isFinite) else { throw ParakeetFailure.invalidAudio }
        operations.lock(); defer { operations.unlock() }
        let result = samples.withUnsafeBufferPointer { cassini_sherpa_decode(handle,$0.baseAddress,Int32($0.count)) }
        guard let result else { throw ParakeetFailure.runtime("Segment decode failed") }
        defer { cassini_sherpa_result_destroy(handle,result) }
        guard let pointer = cassini_sherpa_text(result), let text = String(validatingCString:pointer) else { throw ParakeetFailure.invalidTokens }
        var tokens: [ParakeetToken] = []
        for index in 0..<cassini_sherpa_count(result) {
            guard let pointer = cassini_sherpa_token(result,index), let piece = String(validatingCString:pointer) else { throw ParakeetFailure.invalidTokens }
            tokens.append(.init(text:piece,timestamp:cassini_sherpa_timestamp(result,index),duration:cassini_sherpa_duration(result,index)))
        }
        return .init(text:text.trimmingCharacters(in:.whitespacesAndNewlines),language:"und",words:try ParakeetWords.decode(tokens))
    }
}
