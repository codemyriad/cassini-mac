// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public enum WhistleFailure: Error, CustomStringConvertible {
    case telemetry(String), library(String), model(String), audio, runtime(String)
    public var description: String {
        switch self {
        case .telemetry(let name): return "Required privacy environment missing: " + name
        case .library(let reason): return "Whistle library: " + reason
        case .model(let reason): return "Whistle model: " + reason
        case .audio: return "Expected at most 30 seconds of 16 kHz mono PCM16 WAV"
        case .runtime(let reason): return "Whistle runtime: " + reason
        }
    }
}
public enum WhistleEnvironment {
    public static let required = ["NEEDLE_TELEMETRY": "0", "DO_NOT_TRACK": "1", "ORT_DISABLE_TELEMETRY": "1"]
    public static func validate(_ environment: [String: String]) throws {
        for key in required.keys.sorted() where environment[key] != required[key] { throw WhistleFailure.telemetry(key) }
    }
    public static func validateLive() throws {
        for key in required.keys.sorted() {
            guard let value = getenv(key), String(cString: value) == required[key] else { throw WhistleFailure.telemetry(key) }
        }
    }
    public static func worker(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = required
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result["LANG"] = "C"; result["LC_ALL"] = "C"
        if let temporary = environment["TMPDIR"] { result["TMPDIR"] = temporary }
        return result
    }
}
public struct WhistleTranscript: Codable, Sendable {
    public let text: String
    public let language: String
    public let words: [Word]?
    public struct Word: Codable, Sendable {
        public let word: String; public let start: Double; public let end: Double; public let probability: Double
    }
}

/// Loaded only by the worker process. No engine symbols are linked into the app.
/// The privacy guard runs before dlopen, including library constructors.
public final class WhistleEngine {
    private typealias Load = @convention(c) (UnsafePointer<UInt8>?, UInt64) -> Int32
    private typealias LastError = @convention(c) () -> UnsafePointer<CChar>?
    private typealias Transcribe = @convention(c) (UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32) -> Int32
    private let handle: UnsafeMutableRawPointer
    private let model: UnsafeMutableBufferPointer<UInt8>
    private let operations = NSLock()
    private final class Ownership: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = false
        func acquire() throws { lock.lock(); defer { lock.unlock() }; guard !loaded else { throw WhistleFailure.runtime("only one engine per process is supported") }; loaded = true }
        func release() { lock.lock(); loaded = false; lock.unlock() }
    }
    private static let ownership = Ownership()
    private let transcribeFunction: Transcribe
    private let lastError: LastError

    public init(assets: WhistleAssets) throws {
        try WhistleEnvironment.validateLive()
        try Self.ownership.acquire()
        let bytes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: assets.model.count)
        _ = assets.model.copyBytes(to: bytes)
        guard let handle = dlopen(assets.library.path, RTLD_NOW | RTLD_LOCAL) else {
            bytes.deallocate(); Self.ownership.release()
            throw WhistleFailure.library(dlerror().map { String(cString: $0) } ?? "dlopen failed")
        }
        do {
            let load: Load = try Self.symbol("needle_load", in: handle)
            let transcribe: Transcribe = try Self.symbol("needle_transcribe", in: handle)
            let error: LastError = try Self.symbol("needle_last_error", in: handle)
            let result = load(bytes.baseAddress, UInt64(bytes.count))
            guard result >= 0 else { throw WhistleFailure.model(error().map { String(cString: $0) } ?? "load failed") }
            self.handle = handle; self.model = bytes; self.transcribeFunction = transcribe; self.lastError = error
        } catch { dlclose(handle); bytes.deallocate(); Self.ownership.release(); throw error }
    }
    deinit { dlclose(handle); model.deallocate(); Self.ownership.release() }
    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw WhistleFailure.library("missing symbol " + name) }
        return unsafeBitCast(pointer, to: T.self)
    }
    public func transcribe(wav: URL) throws -> WhistleTranscript {
        operations.lock(); defer { operations.unlock() }
        let pcm = try Self.pcm16(wav)
        var output = [CChar](repeating: 0, count: 1_048_576)
        let result = pcm.withUnsafeBufferPointer { samples in
            "en".withCString { language in
                transcribeFunction(samples.baseAddress, Int32(samples.count), language, nil, 1, &output, Int32(output.count))
            }
        }
        guard result >= 0 else { throw WhistleFailure.runtime(lastError().map { String(cString: $0) } ?? "transcribe failed") }
        let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return try JSONDecoder().decode(WhistleTranscript.self, from: Data(bytes))
    }
    private static func pcm16(_ url: URL) throws -> [Float] {
        let data = try WhistleIO.readRegular(url, maximum: 2_000_000)
        guard data.count >= 44, data.count <= 2_000_000, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { throw WhistleFailure.audio }
        func u16(_ at: Int) -> UInt16 { data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt16.self)) } }
        func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) } }
        var offset = 12; var formatOK = false; var samples: Range<Int>?
        while offset + 8 <= data.count {
            let size = Int(u32(offset + 4)), begin = offset + 8
            guard size <= data.count - begin else { throw WhistleFailure.audio }
            if data[offset..<(offset + 4)] == Data("fmt ".utf8), size >= 16 {
                formatOK = u16(begin) == 1 && u16(begin + 2) == 1 && u32(begin + 4) == 16000 && u16(begin + 12) == 2 && u16(begin + 14) == 16
            }
            if data[offset..<(offset + 4)] == Data("data".utf8) { samples = begin..<(begin + size) }
            offset = begin + size + size % 2
        }
        guard formatOK, let samples, !samples.isEmpty, samples.count % 2 == 0, samples.count <= 16000 * 30 * 2 else { throw WhistleFailure.audio }
        return stride(from: samples.lowerBound, to: samples.upperBound, by: 2).map { Float(Int16(bitPattern: u16($0))) / 32768 }
    }
}
