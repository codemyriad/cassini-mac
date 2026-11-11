// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from cassini-ios #115 at 96d2457; shared D96 transport behavior.
import Foundation
import CoreFoundation
import zlib

/// D96 transport bounds, independent of the limits of an individual audio importer.
public struct ZIPLimits: Sendable {
    public var entries: Int
    public var expandedBytes: UInt64
    public var ratio: UInt64
    public init(entries: Int = 2_000, expandedBytes: UInt64 = 20_000_000_000, ratio: UInt64 = 100) {
        self.entries = entries; self.expandedBytes = expandedBytes; self.ratio = ratio
    }
}

public enum ZIPFailure: Error, Equatable, Hashable, Sendable {
    case damaged, encrypted, unsafePaths, tooLarge, empty
    /// A readable directory can contain an individual corrupt/unsupported entry.
    case entry
}

/// A bounded directory snapshot of a private, immutable local ZIP. No archive path is ever used as a disk path.
/// Stored and raw-deflate members, including ZIP64 and data descriptors, are read in 64 KiB chunks.
public struct ZIPArchive: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let compressedBytes: UInt64
        public let expandedBytes: UInt64
        public let isFile: Bool
        public let method: UInt16
        let offset: UInt64
        let checksum: UInt32
        let readable: Bool
    }
    public let url: URL
    private let limits: ZIPLimits
    public let entries: [Entry]
    public static let chunkBytes = 64 * 1024

    public init(url: URL, limits: ZIPLimits = .init(), check: () throws -> Void = {}) throws {
        self.url = url; self.limits = limits
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 22 else { throw ZIPFailure.damaged }
        let tailSize = Int(min(length, 65_557))
        let tail = try zipRead(file, at: length - UInt64(tailSize), count: tailSize)
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.z32($0) == 0x06054b50 && $0 + 22 + Int(tail.z16($0 + 20)) == tail.count
        }) else { throw ZIPFailure.damaged }
        guard tail.z16(end + 4) == 0, tail.z16(end + 6) == 0,
              tail.z16(end + 8) == tail.z16(end + 10) else { throw ZIPFailure.damaged }
        var count = UInt64(tail.z16(end + 10))
        var size = UInt64(tail.z32(end + 12))
        var start = UInt64(tail.z32(end + 16))
        var boundary = length - UInt64(tailSize) + UInt64(end)
        if count == 0xffff || size == 0xffffffff || start == 0xffffffff {
            guard boundary >= 20 else { throw ZIPFailure.damaged }
            let locator = try zipRead(file, at: boundary - 20, count: 20)
            guard locator.z32(0) == 0x07064b50, locator.z32(4) == 0, locator.z32(16) == 1 else {
                throw ZIPFailure.damaged
            }
            let position = locator.z64(8)
            guard position <= boundary - 20, boundary - 20 - position >= 56 else { throw ZIPFailure.damaged }
            let record = try zipRead(file, at: position, count: 56)
            guard record.z32(0) == 0x06064b50, record.z64(4) >= 44,
                  record.z64(4) <= boundary - 20 - position - 12,
                  record.z32(16) == 0, record.z32(20) == 0,
                  record.z64(24) == record.z64(32) else { throw ZIPFailure.damaged }
            count = record.z64(32); size = record.z64(40); start = record.z64(48)
            boundary = position
        }
        guard count <= UInt64(max(0, limits.entries)) else { throw ZIPFailure.tooLarge }
        guard start <= boundary, size <= boundary - start else { throw ZIPFailure.damaged }
        let directoryEnd = start + size
        var cursor = start
        var expanded: UInt64 = 0
        var result: [Entry] = []
        for _ in 0..<Int(count) {
            try check()
            guard cursor <= directoryEnd, directoryEnd - cursor >= 46 else { throw ZIPFailure.damaged }
            let header = try zipRead(file, at: cursor, count: 46)
            guard header.z32(0) == 0x02014b50 else { throw ZIPFailure.damaged }
            let flags = header.z16(8)
            if flags & 0x2041 != 0 { throw ZIPFailure.encrypted }
            let nameSize = Int(header.z16(28)), extraSize = Int(header.z16(30))
            let variable = nameSize + extraSize + Int(header.z16(32))
            guard UInt64(variable) <= directoryEnd - cursor - 46 else { throw ZIPFailure.damaged }
            let data = try zipRead(file, at: cursor + 46, count: nameSize + extraSize)
            let rawName = Data(data.prefix(nameSize))
            let extra = Data(data.suffix(extraSize))
            let encoding = flags & 0x800 != 0 ? String.Encoding.utf8 :
                String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0400)) // CP437
            guard var name = String(data: rawName, encoding: encoding) else { throw ZIPFailure.damaged }
            try Self.checkPath(name)
            if let unicode = try Self.extra(0x7075, in: extra), unicode.count >= 5, unicode[0] == 1 {
                let crc = rawName.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(rawName.count))) }
                if unicode.z32(1) == crc {
                    guard let path = String(data: unicode.dropFirst(5), encoding: .utf8) else { throw ZIPFailure.damaged }
                    try Self.checkPath(path)
                    if flags & 0x800 == 0 { name = path }
                }
            }
            var packed = UInt64(header.z32(20)), unpacked = UInt64(header.z32(24))
            var offset = UInt64(header.z32(42)), disk = UInt64(header.z16(34))
            if packed == 0xffffffff || unpacked == 0xffffffff || offset == 0xffffffff || disk == 0xffff {
                guard let zip64 = try Self.extra(1, in: extra) else { throw ZIPFailure.damaged }
                var index = 0
                func next(_ width: Int = 8) throws -> UInt64 {
                    guard index + width <= zip64.count else { throw ZIPFailure.damaged }
                    defer { index += width }
                    return width == 8 ? zip64.z64(index) : UInt64(zip64.z32(index))
                }
                if unpacked == 0xffffffff { unpacked = try next() }
                if packed == 0xffffffff { packed = try next() }
                if offset == 0xffffffff { offset = try next() }
                if disk == 0xffff { disk = try next(4) }
            }
            guard disk == 0 else { throw ZIPFailure.damaged }
            guard unpacked <= limits.expandedBytes - expanded else { throw ZIPFailure.tooLarge }
            expanded += unpacked
            if header.z16(10) != 0 { try Self.checkRatio(unpacked, packed, limits.ratio) }
            // Security facts in local headers are checked for every member before import. A broken individual
            // member is retained as unreadable, so one corrupt header does not discard other good notes.
            let payload = try Self.payload(file, at: offset, before: start, flags: flags, method: header.z16(10),
                                           name: rawName, packed: packed)
            let mode = (header.z32(38) >> 16) & 0xf000
            let regular = !name.hasSuffix("/") && mode != 0xa000 && mode != 0x4000
            // Only the first 512 title characters can affect the import's 200-character title. Keep the extension.
            let base = String(name.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
            let ext = (base as NSString).pathExtension
            let display = String((base as NSString).deletingPathExtension.prefix(512)) + (ext.isEmpty ? "" : "." + String(ext.prefix(32)))
            result.append(Entry(name: display, compressedBytes: packed, expandedBytes: unpacked, isFile: regular,
                                method: header.z16(10), offset: payload ?? 0, checksum: header.z32(16), readable: payload != nil))
            cursor += 46 + UInt64(variable)
        }
        guard cursor == directoryEnd else { throw ZIPFailure.damaged }
        entries = result
    }

    /// Streams one member. CRC, exact byte counts and the runtime byte budget are checked even when the consumer
    /// discards an unsupported member. Symlinks remain bytes; no link or directory from a ZIP is ever created.
    @discardableResult public func read(_ entry: Entry, remainingBytes: UInt64, check: () throws -> Void = {},
                                       observed: (Int) throws -> Void = { _ in },
                                       consume: (Data) throws -> Void) throws -> UInt64 {
        guard entry.readable else { throw ZIPFailure.entry }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: entry.offset)
        var bytes: UInt64 = 0, checksum: UInt32 = 0
        func emit(_ data: Data) throws {
            try check()
            guard UInt64(data.count) <= remainingBytes - bytes else { throw ZIPFailure.tooLarge }
            bytes += UInt64(data.count)
            try observed(data.count)
            guard bytes <= entry.expandedBytes else { throw ZIPFailure.entry }
            checksum = data.withUnsafeBytes { UInt32(zlib.crc32(uLong(checksum), $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))) }
            try consume(data)
        }
        var left = entry.compressedBytes
        if entry.method == 0 {
            while left > 0 {
                try check()
                let data = try input.read(upToCount: Int(min(UInt64(Self.chunkBytes), left))) ?? Data()
                guard !data.isEmpty else { throw ZIPFailure.entry }
                left -= UInt64(data.count)
                try emit(data)
            }
        } else if entry.method == 8 {
            var stream = z_stream()
            guard inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZIPFailure.entry }
            defer { inflateEnd(&stream) }
            var ended = false
            while left > 0 && !ended {
                try check()
                let data = try input.read(upToCount: Int(min(UInt64(Self.chunkBytes), left))) ?? Data()
                guard !data.isEmpty else { throw ZIPFailure.entry }
                left -= UInt64(data.count)
                try data.withUnsafeBytes { raw in
                    stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = uInt(data.count)
                    repeat {
                        var output = Data(count: Self.chunkBytes)
                        let before = stream.avail_in
                        let rc = output.withUnsafeMutableBytes { buffer -> Int32 in
                            stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                            stream.avail_out = uInt(Self.chunkBytes)
                            return inflate(&stream, Z_NO_FLUSH)
                        }
                        let produced = Self.chunkBytes - Int(stream.avail_out)
                        do { try emit(Data(output.prefix(produced))) }
                        catch ZIPFailure.entry {
                            // A forged small expanded size must not hide a bomb on the first chunk.
                            try Self.checkRatio(bytes, UInt64(stream.total_in), limits.ratio)
                            throw ZIPFailure.entry
                        }
                        if rc == Z_STREAM_END { ended = true; break }
                        guard rc == Z_OK, produced > 0 || stream.avail_in < before else { throw ZIPFailure.entry }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                }
            }
            // Inflater consumption, not a padded directory length, determines the real ratio.
            try Self.checkRatio(bytes, UInt64(stream.total_in), limits.ratio)
            guard ended, left == 0, stream.avail_in == 0 else { throw ZIPFailure.entry }
        } else { throw ZIPFailure.entry }
        guard bytes == entry.expandedBytes, checksum == entry.checksum else { throw ZIPFailure.entry }
        return bytes
    }

    static func checkPath(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains("\\"),
              !name.contains(":"), !name.contains("\0"), !name.split(separator: "/").contains("..") else {
            throw ZIPFailure.unsafePaths
        }
    }
    private static func payload(_ file: FileHandle, at offset: UInt64, before start: UInt64, flags: UInt16,
                                method: UInt16, name: Data, packed: UInt64) throws -> UInt64? {
        do {
            guard offset <= start, start - offset >= 30 else { return nil }
            let local = try zipRead(file, at: offset, count: 30)
            guard local.z32(0) == 0x04034b50 else { return nil }
            if local.z16(6) & 0x2041 != 0 { throw ZIPFailure.encrypted }
            let names = Int(local.z16(26)), extras = Int(local.z16(28))
            guard UInt64(names + extras) <= start - offset - 30 else { return nil }
            let raw = try zipRead(file, at: offset + 30, count: names)
            let encoding = local.z16(6) & 0x800 != 0 ? String.Encoding.utf8 :
                String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0400))
            guard let localName = String(data: raw, encoding: encoding) else { return nil }
            try checkPath(localName)
            let extra = try zipRead(file, at: offset + 30 + UInt64(names), count: extras)
            if let unicode = try Self.extra(0x7075, in: extra), unicode.count >= 5, unicode[0] == 1 {
                let crc = raw.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(raw.count))) }
                if unicode.z32(1) == crc {
                    guard let path = String(data: unicode.dropFirst(5), encoding: .utf8) else { return nil }
                    try checkPath(path)
                }
            }
            guard local.z16(8) == method, local.z16(6) == flags, raw == name else { return nil }
            let payload = offset + 30 + UInt64(names + extras)
            guard packed <= start - payload else { return nil }
            return payload
        } catch let failure as ZIPFailure {
            if failure == .unsafePaths || failure == .encrypted { throw failure }
            return nil
        } catch { return nil }
    }
    static func checkRatio(_ expanded: UInt64, _ compressed: UInt64, _ ratio: UInt64) throws {
        guard expanded == 0 || (ratio > 0 && compressed > 0 && (expanded - 1) / ratio < compressed) else {
            throw ZIPFailure.tooLarge
        }
    }
    static func extra(_ id: UInt16, in data: Data) throws -> Data? {
        var p = 0
        var found: Data?
        while p < data.count {
            guard data.count - p >= 4 else { throw ZIPFailure.damaged }
            let count = Int(data.z16(p + 2))
            guard count <= data.count - p - 4 else { throw ZIPFailure.damaged }
            if data.z16(p) == id {
                guard found == nil else { throw ZIPFailure.damaged }
                found = Data(data[(p + 4)..<(p + 4 + count)])
            }
            p += 4 + count
        }
        return found
    }
}

func zipRead(_ file: FileHandle, at offset: UInt64, count: Int) throws -> Data {
    try file.seek(toOffset: offset)
    var result = Data()
    while result.count < count {
        let chunk = try file.read(upToCount: count - result.count) ?? Data()
        guard !chunk.isEmpty else { throw ZIPFailure.damaged }
        result.append(chunk)
    }
    return result
}

extension Data {
    func z16(_ p: Int) -> UInt16 { UInt16(self[p]) | UInt16(self[p + 1]) << 8 }
    func z32(_ p: Int) -> UInt32 { UInt32(z16(p)) | UInt32(z16(p + 2)) << 16 }
    func z64(_ p: Int) -> UInt64 { UInt64(z32(p)) | UInt64(z32(p + 4)) << 32 }
    mutating func zip16(_ n: UInt16) { append(UInt8(truncatingIfNeeded: n)); append(UInt8(truncatingIfNeeded: n >> 8)) }
    mutating func zip32(_ n: UInt32) { zip16(UInt16(truncatingIfNeeded: n)); zip16(UInt16(truncatingIfNeeded: n >> 16)) }
    mutating func zip64(_ n: UInt64) { zip32(UInt32(truncatingIfNeeded: n)); zip32(UInt32(truncatingIfNeeded: n >> 32)) }
}
