// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from cassini-ios #115 at 96d2457; shared D96 transport behavior.
import Foundation
import zlib

/// One-pass, stored ZIP64 output. Member bytes are streamed once; the directory is written once at the end.
/// The caller owns the private output folder and removes it if any operation throws (including cancellation).
public final class StoredZIPWriter {
    private struct Member { let name: Data; let size: UInt64; let checksum: UInt32; let offset: UInt64; let time: UInt16; let date: UInt16 }
    private let file: FileHandle
    private let limits: ZIPLimits
    private var members: [Member] = []
    private var bytes: UInt64 = 0
    private var finished = false

    public init(url: URL, limits: ZIPLimits = .init()) throws {
        self.limits = limits
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        file = try FileHandle(forWritingTo: url)
    }
    deinit { try? file.close() }

    public func add(file source: URL, name: String, check: () throws -> Void = {}) throws {
        try check()
        guard !finished, members.count < limits.entries else { throw ZIPFailure.tooLarge }
        try ZIPArchive.checkPath(name)
        guard !name.contains("/") else { throw ZIPFailure.unsafePaths }
        let encoded = Data(name.utf8)
        guard encoded.count <= Int(UInt16.max) else { throw ZIPFailure.entry }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        try input.seek(toOffset: 0)
        guard size <= limits.expandedBytes - bytes else { throw ZIPFailure.tooLarge }
        let offset = try file.offset()
        // Like Android ZipOutputStream: archive creation time, never a source of meeting time on import.
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
        let year = UInt16(min(2107,max(1980,c.year ?? 1980)) - 1980)
        let month = UInt16(c.month ?? 1), day = UInt16(c.day ?? 1)
        let hour = UInt16(c.hour ?? 0), minute = UInt16(c.minute ?? 0), second = UInt16(c.second ?? 0)
        let date = (year << 9) | (month << 5) | day
        let time = (hour << 11) | (minute << 5) | (second / 2)
        var header = Data()
        header.zip32(0x04034b50); header.zip16(45); header.zip16(0x800); header.zip16(0)
        header.zip16(time); header.zip16(date); header.zip32(0)
        header.zip32(.max); header.zip32(.max); header.zip16(UInt16(encoded.count)); header.zip16(20)
        header.append(encoded); header.zip16(1); header.zip16(16); header.zip64(size); header.zip64(size)
        try file.write(contentsOf: header)
        var read: UInt64 = 0, checksum: UInt32 = 0
        while true {
            try check()
            let chunk = try input.read(upToCount: ZIPArchive.chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            guard UInt64(chunk.count) <= size - read else { throw ZIPFailure.entry }
            read += UInt64(chunk.count)
            checksum = chunk.withUnsafeBytes { UInt32(zlib.crc32(uLong(checksum), $0.bindMemory(to: UInt8.self).baseAddress, uInt(chunk.count))) }
            try file.write(contentsOf: chunk)
        }
        guard read == size else { throw ZIPFailure.entry }
        let end = try file.offset()
        try file.seek(toOffset: offset + 14)
        var crc = Data(); crc.zip32(checksum); try file.write(contentsOf: crc)
        try file.seek(toOffset: end)
        bytes += size
        members.append(Member(name: encoded, size: size, checksum: checksum, offset: offset, time: time, date: date))
    }

    public func finish(check: () throws -> Void = {}) throws {
        guard !finished else { throw ZIPFailure.entry }
        let start = try file.offset()
        for member in members {
            try check()
            var record = Data()
            record.zip32(0x02014b50); record.zip16(45); record.zip16(45); record.zip16(0x800); record.zip16(0)
            record.zip16(member.time); record.zip16(member.date); record.zip32(member.checksum)
            record.zip32(.max); record.zip32(.max); record.zip16(UInt16(member.name.count)); record.zip16(28)
            record.zip16(0); record.zip16(0); record.zip16(0); record.zip32(0); record.zip32(.max)
            record.append(member.name); record.zip16(1); record.zip16(24)
            record.zip64(member.size); record.zip64(member.size); record.zip64(member.offset)
            try file.write(contentsOf: record)
        }
        let end = try file.offset()
        var footer = Data()
        footer.zip32(0x06064b50); footer.zip64(44); footer.zip16(45); footer.zip16(45)
        footer.zip32(0); footer.zip32(0); footer.zip64(UInt64(members.count)); footer.zip64(UInt64(members.count))
        footer.zip64(end - start); footer.zip64(start)
        footer.zip32(0x07064b50); footer.zip32(0); footer.zip64(end); footer.zip32(1)
        footer.zip32(0x06054b50); footer.zip16(0); footer.zip16(0); footer.zip16(.max); footer.zip16(.max)
        footer.zip32(.max); footer.zip32(.max); footer.zip16(0)
        try file.write(contentsOf: footer)
        try file.synchronize()
        try file.close()
        finished = true
    }
}
