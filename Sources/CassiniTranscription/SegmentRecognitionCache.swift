// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import CoreFoundation
import Darwin
import CassiniKit
import CassiniLibrary
import CassiniWhistle

/// Wave 0 desktop pure segment-PCM recognition cache (`cassini.recognition-cache.v2`, D-1117 / D109).
/// Stores ONLY raw segment-relative recognizer output `(relativeWords, text, language)` strictly keyed
/// on `(modelIdentity, pcmF32Sha256, sampleCount)`. All placement (D55), clamping (G11), presence/ownership
/// midpoint filtering (D63 #3), and fallback filtering (R71) run strictly at post-Stop finalization.
public enum SegmentRecognitionCache {
    public static let format = "cassini.recognition-cache.v2"
    public static let filename = ".recognition-cache.json"
    public static let maxCacheFileBytes = 16 * 1024 * 1024
    public static let maxCacheSegments = 100_000
    public static let maxCachedWords = 10_000
    public static let maxRelativeWordMs: Int64 = 86_400_000
    public static let maxSampleCount = 1_382_400_000
    public static let maxModelIdentityBytes = 256
    public static let maxLanguageBytes = 32

    public struct RelativeWord: Codable, Equatable, Sendable {
        public let startMs: Int64
        public let endMs: Int64
        public let text: String

        public init(startMs: Int64, endMs: Int64, text: String) {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let sampleCount: Int
        public let text: String
        public let language: String
        public let relativeWords: [RelativeWord]

        public init(sampleCount: Int, text: String, language: String, relativeWords: [RelativeWord]) {
            self.sampleCount = sampleCount
            self.text = text
            self.language = language
            self.relativeWords = relativeWords
        }
    }

    public enum RejectReason: String, Error, Equatable, Sendable {
        case unsupportedFormat
        case modelMismatch
        case invalidDocument
        case cacheMiss
        case sampleCountMismatch
        case invalidEntry
    }

    public struct LookupResult: Equatable, Sendable {
        public let derivedKey: String
        public let entry: Entry?
        public let rejectReason: RejectReason?

        public var isHit: Bool { entry != nil && rejectReason == nil }
    }

    public static func isValidModelIdentity(_ modelIdentity: String) -> Bool {
        let utf8 = modelIdentity.utf8
        guard !utf8.isEmpty, utf8.count <= maxModelIdentityBytes else { return false }
        return !utf8.contains(0x0A) && !utf8.contains(0x0D) && !utf8.contains(0x00)
    }

    public static func isHex64(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// 64-char lowercase hex SHA-256 over the exact 16 kHz mono IEEE-754 little-endian `<f4` PCM bytes.
    /// Returns nil if `samples` is empty, exceeds 24 h, or contains any non-finite value.
    public static func pcmF32Sha256(_ samples: [Float]) -> String? {
        guard !samples.isEmpty, samples.count <= maxSampleCount else { return nil }
        for sample in samples {
            guard sample.isFinite else { return nil }
        }
        var hasher = SHA256()
        var chunk = [UInt32](repeating: 0, count: min(samples.count, 4096))
        var index = 0
        while index < samples.count {
            let count = min(chunk.count, samples.count - index)
            for i in 0..<count {
                chunk[i] = samples[index + i].bitPattern.littleEndian
            }
            chunk.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: count * 4))
            }
            index += count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Derives the canonical `cassini.recognition-cache.v2` 64-hex key.
    public static func deriveKey(modelIdentity: String, pcmF32Sha256: String, sampleCount: Int) -> String? {
        guard isValidModelIdentity(modelIdentity),
              isHex64(pcmF32Sha256),
              sampleCount >= 1, sampleCount <= maxSampleCount else { return nil }
        let preimage = "\(format)\n\(modelIdentity)\n\(pcmF32Sha256)\n\(sampleCount)"
        return SHA256.hash(data: Data(preimage.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func deriveKey(modelIdentity: String, samples: [Float]) -> String? {
        guard let pcmHash = pcmF32Sha256(samples) else { return nil }
        return deriveKey(modelIdentity: modelIdentity, pcmF32Sha256: pcmHash, sampleCount: samples.count)
    }

    /// Converts raw recognizer output into a validated pure cache entry using IEEE round-to-nearest-even.
    public static func entry(from transcript: WhistleTranscript, sampleCount: Int) -> Entry? {
        guard sampleCount >= 1, sampleCount <= maxSampleCount else { return nil }
        let normalizedLanguage = TranscriptLanguage.written(transcript.language)
        guard !normalizedLanguage.isEmpty, normalizedLanguage.utf8.count <= maxLanguageBytes else { return nil }
        let rawWords = transcript.words ?? []
        guard rawWords.count <= maxCachedWords else { return nil }
        var relativeWords: [RelativeWord] = []
        relativeWords.reserveCapacity(rawWords.count)
        for word in rawWords {
            guard word.start.isFinite, word.end.isFinite,
                  word.start >= 0, word.end >= word.start, word.end <= 86400.0,
                  !word.word.isEmpty else { return nil }
            let startMs = Int64((word.start * 1000.0).rounded(.toNearestOrEven))
            let endMs = max(startMs, Int64((word.end * 1000.0).rounded(.toNearestOrEven)))
            guard startMs >= 0, endMs >= startMs, endMs <= maxRelativeWordMs else { return nil }
            relativeWords.append(RelativeWord(startMs: startMs, endMs: endMs, text: word.word))
        }
        return Entry(sampleCount: sampleCount, text: transcript.text, language: normalizedLanguage, relativeWords: relativeWords)
    }

    /// Strict exact-integer JSON extraction (rejects booleans and floating-point numbers such as `120.5`).
    private static func exactInt64(_ raw: Any?) -> Int64? {
        guard let number = raw as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if CFNumberIsFloatType(number) { return nil }
        let value = number.int64Value
        // Double-check against out-of-range unsigned values.
        if number.doubleValue < Double(Int64.min) || number.doubleValue > Double(Int64.max) { return nil }
        return value
    }

    private static func validateEntry(_ raw: Any, expectedSampleCount: Int?) -> Result<Entry, RejectReason> {
        guard let dict = raw as? [String: Any] else { return .failure(.invalidEntry) }
        guard let sampleCount64 = exactInt64(dict["sampleCount"]),
              sampleCount64 >= 1, sampleCount64 <= Int64(maxSampleCount) else {
            return .failure(.invalidEntry)
        }
        let sampleCount = Int(sampleCount64)
        if let expectedSampleCount, sampleCount != expectedSampleCount {
            return .failure(.sampleCountMismatch)
        }
        guard let text = dict["text"] as? String,
              let language = dict["language"] as? String,
              !language.isEmpty, language.utf8.count <= maxLanguageBytes,
              let rawWords = dict["relativeWords"] as? [Any],
              rawWords.count <= maxCachedWords else {
            return .failure(.invalidEntry)
        }
        var words: [RelativeWord] = []
        words.reserveCapacity(rawWords.count)
        for item in rawWords {
            guard let wordDict = item as? [String: Any],
                  let startMs = exactInt64(wordDict["startMs"]),
                  let endMs = exactInt64(wordDict["endMs"]),
                  startMs >= 0, endMs >= startMs, endMs <= maxRelativeWordMs,
                  let wordText = wordDict["text"] as? String,
                  !wordText.isEmpty else {
                return .failure(.invalidEntry)
            }
            words.append(RelativeWord(startMs: startMs, endMs: endMs, text: wordText))
        }
        return .success(Entry(sampleCount: sampleCount, text: text, language: language, relativeWords: words))
    }

    /// Validates a serialized JSON cache document and looks up one query.
    public static func lookup(
        documentData: Data,
        modelIdentity: String,
        pcmF32Sha256: String,
        sampleCount: Int
    ) -> LookupResult {
        guard let derivedKey = deriveKey(modelIdentity: modelIdentity, pcmF32Sha256: pcmF32Sha256, sampleCount: sampleCount) else {
            return LookupResult(derivedKey: "", entry: nil, rejectReason: .invalidDocument)
        }
        guard documentData.count <= maxCacheFileBytes,
              let root = (try? JSONSerialization.jsonObject(with: documentData)) as? [String: Any] else {
            return LookupResult(derivedKey: derivedKey, entry: nil, rejectReason: .invalidDocument)
        }
        guard let docFormat = root["format"] as? String, docFormat == format else {
            return LookupResult(derivedKey: derivedKey, entry: nil, rejectReason: .unsupportedFormat)
        }
        guard let docModel = root["model"] as? String, docModel == modelIdentity else {
            return LookupResult(derivedKey: derivedKey, entry: nil, rejectReason: .modelMismatch)
        }
        guard let segments = root["segments"] as? [String: Any], segments.count <= maxCacheSegments else {
            return LookupResult(derivedKey: derivedKey, entry: nil, rejectReason: .invalidDocument)
        }
        guard let rawEntry = segments[derivedKey] else {
            return LookupResult(derivedKey: derivedKey, entry: nil, rejectReason: .cacheMiss)
        }
        switch validateEntry(rawEntry, expectedSampleCount: sampleCount) {
        case .success(let entry):
            return LookupResult(derivedKey: derivedKey, entry: entry, rejectReason: nil)
        case .failure(let reason):
            return LookupResult(derivedKey: derivedKey, entry: nil, rejectReason: reason)
        }
    }

    /// Mutable in-memory cache store backed by `.recognition-cache.json`.
    public struct Store: Sendable {
        public let modelIdentity: String
        private var segments: [String: Entry]

        public init(modelIdentity: String, segments: [String: Entry] = [:]) {
            self.modelIdentity = modelIdentity
            self.segments = segments
        }

        public var count: Int { segments.count }

        /// Loads `.recognition-cache.json` safely (`O_RDONLY | O_NOFOLLOW`, regular file, <= 16 MiB).
        /// Any legacy version (`v1`), model mismatch, symlink, or corrupt JSON is ignored as an empty cache.
        public static func load(directory: URL, modelIdentity: String) -> Store {
            guard isValidModelIdentity(modelIdentity) else { return Store(modelIdentity: modelIdentity) }
            let url = directory.appendingPathComponent(filename)
            guard let data = try? WhistleIO.readRegular(url, maximum: maxCacheFileBytes),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (root["format"] as? String) == format,
                  (root["model"] as? String) == modelIdentity,
                  let rawSegments = root["segments"] as? [String: Any],
                  rawSegments.count <= maxCacheSegments else {
                return Store(modelIdentity: modelIdentity)
            }
            var valid: [String: Entry] = [:]
            valid.reserveCapacity(rawSegments.count)
            for (key, rawEntry) in rawSegments where isHex64(key) {
                if case .success(let entry) = validateEntry(rawEntry, expectedSampleCount: nil) {
                    valid[key] = entry
                }
            }
            return Store(modelIdentity: modelIdentity, segments: valid)
        }

        public func lookup(samples: [Float]) -> (key: String, entry: Entry)? {
            guard let key = SegmentRecognitionCache.deriveKey(modelIdentity: modelIdentity, samples: samples),
                  let entry = segments[key],
                  entry.sampleCount == samples.count else { return nil }
            return (key, entry)
        }

        public mutating func insert(key: String, entry: Entry) {
            guard isHex64(key), segments.count < maxCacheSegments || segments[key] != nil else { return }
            segments[key] = entry
        }

        public func encodedData() throws -> Data {
            struct Envelope: Encodable {
                let format: String
                let model: String
                let segments: [String: Entry]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(format: SegmentRecognitionCache.format, model: modelIdentity, segments: segments))
            guard data.count <= maxCacheFileBytes else { throw TranscriptionFailure.runtime("recognition cache size limit") }
            return data
        }

        /// Atomically writes `.recognition-cache.json` without acquiring `.transcription.lock`.
        public func saveAtomically(to directory: URL) throws {
            guard isValidModelIdentity(modelIdentity) else { return }
            let data = try encodedData()
            let target = directory.appendingPathComponent(filename)
            var existing = stat()
            if lstat(target.path, &existing) == 0, existing.st_mode & S_IFMT != S_IFREG {
                // Never replace a non-regular entry (e.g. symlink).
                return
            }
            let temp = directory.appendingPathComponent(".recognition-cache-" + UUID().uuidString + ".tmp")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = unlink(temp.path) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        public static func remove(in directory: URL) {
            let target = directory.appendingPathComponent(filename)
            var info = stat()
            if lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                _ = unlink(target.path)
            }
        }
    }
}
