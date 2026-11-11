// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import zlib
import CryptoKit
import CassiniKit
import Testing
@testable import CassiniLibrary

@Suite struct LibraryImportZipTests {
    // MARK: - Synthetic ZIP32 / ZIP64 Builder

    private struct RawZipEntry {
        var centralName: Data
        var localName: Data?
        var centralFlags: UInt16 = 0x0800
        var localFlags: UInt16?
        var centralMethod: UInt16 = 0
        var localMethod: UInt16?
        var compressedPayload: Data = Data()
        var centralCRC: UInt32?
        var localCRC: UInt32?
        var centralCompressedSize: UInt64?
        var centralUncompressedSize: UInt64?
        var localCompressedSize32: UInt32?
        var localUncompressedSize32: UInt32?
        var centralExtra: Data = Data()
        var localExtra: Data = Data()
        var externalAttributes: UInt32 = UInt32(0o100644) << 16
        var appendDataDescriptor: Bool = false
        var forceZip64Extra: Bool = false
        var diskStart16: UInt16 = 0

        init(
            name: String,
            method: UInt16 = 0,
            uncompressedData: Data = Data(),
            flags: UInt16 = 0x0800,
            isDirectory: Bool = false
        ) {
            self.centralName = Data(name.utf8)
            self.centralFlags = flags
            self.centralMethod = method
            if isDirectory {
                self.externalAttributes = (UInt32(S_IFDIR | 0o755) << 16) | 0x10
                self.compressedPayload = Data()
                self.centralCRC = 0
                self.centralCompressedSize = 0
                self.centralUncompressedSize = 0
            } else if method == 8 {
                let deflated = Self.rawDeflate(uncompressedData)
                self.compressedPayload = deflated
                self.centralCRC = Self.crc32(uncompressedData)
                self.centralCompressedSize = UInt64(deflated.count)
                self.centralUncompressedSize = UInt64(uncompressedData.count)
            } else {
                self.compressedPayload = uncompressedData
                self.centralCRC = Self.crc32(uncompressedData)
                self.centralCompressedSize = UInt64(uncompressedData.count)
                self.centralUncompressedSize = UInt64(uncompressedData.count)
            }
        }

        static func crc32(_ data: Data) -> UInt32 {
            let value = data.withUnsafeBytes { raw -> uLong in
                let initCRC = zlib.crc32(0, nil, 0)
                guard let ptr = raw.bindMemory(to: Bytef.self).baseAddress, !raw.isEmpty else {
                    return initCRC
                }
                return zlib.crc32(initCRC, ptr, uInt(raw.count))
            }
            return UInt32(truncatingIfNeeded: value)
        }

        static func rawDeflate(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) -> Data {
            var stream = z_stream()
            precondition(deflateInit2_(&stream, level, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
            defer { deflateEnd(&stream) }

            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            data.withUnsafeBytes { rawIn in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: rawIn.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(rawIn.count)
                repeat {
                    chunk.withUnsafeMutableBufferPointer { outBuf in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = uInt(outBuf.count)
                        let rc = deflate(&stream, Z_FINISH)
                        precondition(rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR)
                        let have = outBuf.count - Int(stream.avail_out)
                        if have > 0 {
                            output.append(outBuf.baseAddress!, count: have)
                        }
                    }
                } while stream.avail_out == 0
            }
            return output
        }
    }

    private static func buildZip(
        entries: [RawZipEntry],
        forceAllZip64Sentinels: Bool = false,
        comment: Data = Data()
    ) -> Data {
        var archive = Data()
        var offsets: [UInt64] = []

        for entry in entries {
            let localOffset = UInt64(archive.count)
            offsets.append(localOffset)

            let lName = entry.localName ?? entry.centralName
            let lFlags = entry.localFlags ?? entry.centralFlags
            let lMethod = entry.localMethod ?? entry.centralMethod
            let cCRC = entry.centralCRC ?? 0
            let lCRC = entry.localCRC ?? ((lFlags & 0x0008) != 0 ? 0 : cCRC)
            let cComp = entry.centralCompressedSize ?? UInt64(entry.compressedPayload.count)
            let cUncomp = entry.centralUncompressedSize ?? UInt64(entry.compressedPayload.count)

            var lExtra = entry.localExtra
            let needsLocal64 = entry.forceZip64Extra || cComp >= 0xFFFF_FFFF || cUncomp >= 0xFFFF_FFFF
            let lComp32: UInt32
            let lUncomp32: UInt32
            if let explicitComp = entry.localCompressedSize32, let explicitUncomp = entry.localUncompressedSize32 {
                lComp32 = explicitComp
                lUncomp32 = explicitUncomp
            } else if (lFlags & 0x0008) != 0 {
                lComp32 = 0
                lUncomp32 = 0
            } else if needsLocal64 {
                lComp32 = 0xFFFF_FFFF
                lUncomp32 = 0xFFFF_FFFF
                var z64 = Data()
                z64.appendTestU16LE(0x0001)
                z64.appendTestU16LE(16)
                z64.appendTestU64LE(cUncomp)
                z64.appendTestU64LE(cComp)
                lExtra.append(z64)
            } else {
                lComp32 = UInt32(cComp)
                lUncomp32 = UInt32(cUncomp)
            }

            archive.appendTestU32LE(0x0403_4b50)
            archive.appendTestU16LE(needsLocal64 ? 45 : 20)
            archive.appendTestU16LE(lFlags)
            archive.appendTestU16LE(lMethod)
            archive.appendTestU16LE(0)
            archive.appendTestU16LE(0x21)
            archive.appendTestU32LE(lCRC)
            archive.appendTestU32LE(lComp32)
            archive.appendTestU32LE(lUncomp32)
            archive.appendTestU16LE(UInt16(lName.count))
            archive.appendTestU16LE(UInt16(lExtra.count))
            archive.append(lName)
            archive.append(lExtra)
            archive.append(entry.compressedPayload)

            if entry.appendDataDescriptor {
                archive.appendTestU32LE(0x0807_4b50)
                archive.appendTestU32LE(cCRC)
                archive.appendTestU32LE(UInt32(truncatingIfNeeded: cComp))
                archive.appendTestU32LE(UInt32(truncatingIfNeeded: cUncomp))
            }
        }

        let cdOffset = UInt64(archive.count)
        for (i, entry) in entries.enumerated() {
            let cCRC = entry.centralCRC ?? 0
            let cComp = entry.centralCompressedSize ?? UInt64(entry.compressedPayload.count)
            let cUncomp = entry.centralUncompressedSize ?? UInt64(entry.compressedPayload.count)
            let lOffset = offsets[i]

            let useUncomp64 = entry.forceZip64Extra || cUncomp >= 0xFFFF_FFFF
            let useComp64 = entry.forceZip64Extra || cComp >= 0xFFFF_FFFF
            let useOffset64 = entry.forceZip64Extra || lOffset >= 0xFFFF_FFFF
            let useDisk64 = entry.diskStart16 == 0xFFFF

            var cExtra = entry.centralExtra
            if useUncomp64 || useComp64 || useOffset64 || useDisk64 {
                var payload = Data()
                if useUncomp64 { payload.appendTestU64LE(cUncomp) }
                if useComp64 { payload.appendTestU64LE(cComp) }
                if useOffset64 { payload.appendTestU64LE(lOffset) }
                if useDisk64 { payload.appendTestU32LE(0) }
                cExtra.appendTestU16LE(0x0001)
                cExtra.appendTestU16LE(UInt16(payload.count))
                cExtra.append(payload)
            }

            let needs64 = useUncomp64 || useComp64 || useOffset64 || useDisk64
            archive.appendTestU32LE(0x0201_4b50)
            archive.appendTestU16LE((3 << 8) | (needs64 ? 45 : 20))
            archive.appendTestU16LE(needs64 ? 45 : 20)
            archive.appendTestU16LE(entry.centralFlags)
            archive.appendTestU16LE(entry.centralMethod)
            archive.appendTestU16LE(0)
            archive.appendTestU16LE(0x21)
            archive.appendTestU32LE(cCRC)
            archive.appendTestU32LE(useComp64 ? 0xFFFF_FFFF : UInt32(cComp))
            archive.appendTestU32LE(useUncomp64 ? 0xFFFF_FFFF : UInt32(cUncomp))
            archive.appendTestU16LE(UInt16(entry.centralName.count))
            archive.appendTestU16LE(UInt16(cExtra.count))
            archive.appendTestU16LE(0)
            archive.appendTestU16LE(entry.diskStart16)
            archive.appendTestU16LE(0)
            archive.appendTestU32LE(entry.externalAttributes)
            archive.appendTestU32LE(useOffset64 ? 0xFFFF_FFFF : UInt32(lOffset))
            archive.append(entry.centralName)
            archive.append(cExtra)
        }

        let cdSize = UInt64(archive.count) - cdOffset
        let count = UInt64(entries.count)
        let writeZip64 = forceAllZip64Sentinels || count >= 0xFFFF || cdSize >= 0xFFFF_FFFF || cdOffset >= 0xFFFF_FFFF

        if writeZip64 {
            let z64Offset = UInt64(archive.count)
            archive.appendTestU32LE(0x0606_4b50)
            archive.appendTestU64LE(44)
            archive.appendTestU16LE((3 << 8) | 45)
            archive.appendTestU16LE(45)
            archive.appendTestU32LE(0)
            archive.appendTestU32LE(0)
            archive.appendTestU64LE(count)
            archive.appendTestU64LE(count)
            archive.appendTestU64LE(cdSize)
            archive.appendTestU64LE(cdOffset)

            archive.appendTestU32LE(0x0706_4b50)
            archive.appendTestU32LE(0)
            archive.appendTestU64LE(z64Offset)
            archive.appendTestU32LE(1)
        }

        archive.appendTestU32LE(0x0605_4b50)
        archive.appendTestU16LE(forceAllZip64Sentinels ? 0xFFFF : 0)
        archive.appendTestU16LE(forceAllZip64Sentinels ? 0xFFFF : 0)
        let count16: UInt16 = (forceAllZip64Sentinels || count >= 0xFFFF) ? 0xFFFF : UInt16(count)
        archive.appendTestU16LE(count16)
        archive.appendTestU16LE(count16)
        archive.appendTestU32LE((forceAllZip64Sentinels || cdSize >= 0xFFFF_FFFF) ? 0xFFFF_FFFF : UInt32(cdSize))
        archive.appendTestU32LE((forceAllZip64Sentinels || cdOffset >= 0xFFFF_FFFF) ? 0xFFFF_FFFF : UInt32(cdOffset))
        archive.appendTestU16LE(UInt16(comment.count))
        archive.append(comment)
        return archive
    }

    private static func untitledPlainOpus(from f: Fixture) throws -> Data {
        let raw = try Data(contentsOf: f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus"))
        let out = f.root.appendingPathComponent("untitled-\(UUID().uuidString).opus")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try OpusStreamFile.rewrite(raw, tags: PortableMeetingTags.packet(), to: out)
        return try Data(contentsOf: out)
    }

    // MARK: - 1. Archive Limits (2,000 entries, 20 GB, > 100:1 ratio, forged & padded bombs)

    @Test func entryLimitCountsNonDirectoryEntriesUpToTwoThousandAndIgnoresDirectories() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let staging = f.root.appendingPathComponent("Temp")
        let opusBytes = try Self.untitledPlainOpus(from: f)

        // 2,001 non-directory entries -> refused with tooLarge.
        var overLimit: [RawZipEntry] = [RawZipEntry(name: "Valid.opus", method: 0, uncompressedData: opusBytes)]
        for i in 0..<2_000 {
            overLimit.append(RawZipEntry(name: "note-\(i).txt", method: 0, uncompressedData: Data("ok".utf8)))
        }
        let overURL = f.root.appendingPathComponent("over-limit.zip")
        try Self.buildZip(entries: overLimit).write(to: overURL)
        var summaryOver = LibraryImportSummary()
        #expect(throws: ZipArchiveFailure.tooLarge) {
            try ZipArchiveImport.importArchive(overURL, into: library, temporaryRoot: staging, summary: &summaryOver)
        }
        #expect(!FileManager.default.fileExists(atPath: library.path))

        // Exactly 2,000 non-directory entries + 50 directory entries -> accepted; directories not counted at all.
        var exactEntries: [RawZipEntry] = []
        for d in 0..<50 {
            exactEntries.append(RawZipEntry(name: "dir-\(d)/", isDirectory: true))
        }
        exactEntries.append(RawZipEntry(name: "dir-0/Team sync.opus", method: 8, uncompressedData: opusBytes))
        for i in 0..<1_999 {
            exactEntries.append(RawZipEntry(name: "dir-0/note-\(i).txt", method: 0, uncompressedData: Data("note".utf8)))
        }
        let exactURL = f.root.appendingPathComponent("exact-2000.zip")
        try Self.buildZip(entries: exactEntries).write(to: exactURL)

        var summaryExact = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(exactURL, into: library, temporaryRoot: staging, summary: &summaryExact)
        #expect(summaryExact.imported == 1)
        #expect(summaryExact.unsupported == 1_999)
        #expect(summaryExact.duplicates == 0)
        #expect(summaryExact.failed == 0)
        #expect(summaryExact.lastSelected?.title == "Team sync")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func declaredTwentyGigabyteAndOverflowTotalsRefuseWithTooLarge() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")

        var e1 = RawZipEntry(name: "a.opus", method: 8, uncompressedData: Data("x".utf8))
        e1.forceZip64Extra = true
        e1.centralCompressedSize = 200_000_000
        e1.centralUncompressedSize = 10_000_000_000

        var e2 = RawZipEntry(name: "b.opus", method: 8, uncompressedData: Data("y".utf8))
        e2.forceZip64Extra = true
        e2.centralCompressedSize = 200_000_000
        e2.centralUncompressedSize = 10_000_000_001

        let over20GB = f.root.appendingPathComponent("over20gb.zip")
        try Self.buildZip(entries: [e1, e2]).write(to: over20GB)
        var summary = LibraryImportSummary()
        #expect(throws: ZipArchiveFailure.tooLarge) {
            try ZipArchiveImport.importArchive(over20GB, into: library, summary: &summary)
        }

        // 64-bit overflow attempt in Central Directory sum.
        var overflowEntry = e2
        overflowEntry.centralCompressedSize = UInt64.max / 50
        overflowEntry.centralUncompressedSize = UInt64.max - 5
        let overflowZip = f.root.appendingPathComponent("overflow.zip")
        try Self.buildZip(entries: [e1, overflowEntry]).write(to: overflowZip)
        #expect(throws: ZipArchiveFailure.tooLarge) {
            try ZipArchiveImport.importArchive(overflowZip, into: library, summary: &summary)
        }
    }

    @Test(arguments: ["bomb.opus", "bomb.txt"])
    func ratioLimitForgedSizesAndZeroPaddedDeflateBombsRefuseAndRollbackEarlierEntries(bombName: String) throws {
        // Exact arithmetic checks at boundary and UInt64.max.
        #expect(!ZipArchiveImport.exceedsCompressionRatio(uncompressed: 0, compressed: 0))
        #expect(ZipArchiveImport.exceedsCompressionRatio(uncompressed: 1, compressed: 0))
        #expect(!ZipArchiveImport.exceedsCompressionRatio(uncompressed: 10_000, compressed: 100))
        #expect(ZipArchiveImport.exceedsCompressionRatio(uncompressed: 10_001, compressed: 100))
        #expect(!ZipArchiveImport.exceedsCompressionRatio(uncompressed: UInt64.max, compressed: UInt64.max))

        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let staging = f.root.appendingPathComponent("Temp")
        let validOpus = try Data(contentsOf: f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus"))

        // 1. Declared ratio > 100:1 in Central Directory -> refused immediately.
        let declaredBomb = RawZipEntry(name: bombName, method: 8, uncompressedData: Data(repeating: 0, count: 50_000))
        #expect(ZipArchiveImport.exceedsCompressionRatio(
            uncompressed: declaredBomb.centralUncompressedSize!,
            compressed: declaredBomb.centralCompressedSize!
        ))
        let declaredURL = f.root.appendingPathComponent("declared-\(bombName).zip")
        try Self.buildZip(entries: [RawZipEntry(name: "Good.opus", method: 0, uncompressedData: validOpus), declaredBomb]).write(to: declaredURL)
        var s1 = LibraryImportSummary()
        #expect(throws: ZipArchiveFailure.tooLarge) {
            try ZipArchiveImport.importArchive(declaredURL, into: library, temporaryRoot: staging, summary: &s1)
        }
        #expect(!FileManager.default.fileExists(atPath: library.path))

        // 2. Forged small uncompressedSize (claims 16 bytes for a 50,000-byte deflate bomb) AFTER a valid .opus entry!
        var forgedBomb = RawZipEntry(name: bombName, method: 8, uncompressedData: Data(repeating: 0, count: 50_000))
        forgedBomb.centralUncompressedSize = 16
        forgedBomb.localUncompressedSize32 = 16
        forgedBomb.localCompressedSize32 = UInt32(forgedBomb.compressedPayload.count)
        let forgedURL = f.root.appendingPathComponent("forged-\(bombName).zip")
        try Self.buildZip(entries: [RawZipEntry(name: "Good.opus", method: 0, uncompressedData: validOpus), forgedBomb]).write(to: forgedURL)

        var s2 = LibraryImportSummary()
        #expect(throws: ZipArchiveFailure.tooLarge) {
            try ZipArchiveImport.importArchive(forgedURL, into: library, temporaryRoot: staging, summary: &s2)
        }
        #expect(s2.imported == 0)
        // Earlier "Good.opus" created during the same archive run MUST be rolled back!
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
        #expect(remaining.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)

        // 3. Zero-padded compressed data bomb: trailing zero bytes inflate compressedSize so declared ratio <= 100:1,
        // while actual consumed deflate bytes expand > 100:1.
        var paddedBomb = RawZipEntry(name: bombName, method: 8, uncompressedData: Data(repeating: 0, count: 50_000))
        paddedBomb.compressedPayload.append(Data(repeating: 0, count: 1_000))
        paddedBomb.centralCompressedSize = UInt64(paddedBomb.compressedPayload.count)
        paddedBomb.localCompressedSize32 = UInt32(paddedBomb.compressedPayload.count)
        paddedBomb.localUncompressedSize32 = 50_000
        #expect(!ZipArchiveImport.exceedsCompressionRatio(
            uncompressed: paddedBomb.centralUncompressedSize!,
            compressed: paddedBomb.centralCompressedSize!
        ))
        let paddedURL = f.root.appendingPathComponent("padded-\(bombName).zip")
        try Self.buildZip(entries: [RawZipEntry(name: "Good.opus", method: 0, uncompressedData: validOpus), paddedBomb]).write(to: paddedURL)

        var s3 = LibraryImportSummary()
        #expect(throws: ZipArchiveFailure.tooLarge) {
            try ZipArchiveImport.importArchive(paddedURL, into: library, temporaryRoot: staging, summary: &s3)
        }
        #expect(s3.imported == 0)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)
    }

    // MARK: - 2. ZIP64 (Classic EOCD 0xFFFF Sentinels + Real > 4 GiB Sparse Archive & Single-Entry Failure)

    @Test func zip64WithClassicEndRecordSentinelsAndHeaderFlagDifferencesImportsCleanly() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let staging = f.root.appendingPathComponent("Temp")
        let opus1 = try Data(contentsOf: f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus"))
        let opus2 = try Self.untitledPlainOpus(from: f)

        // Entry 1: Local header uses data descriptor bit 3 (0x0008) with zeroed local CRC/sizes,
        // while Central Directory has UTF-8 (0x0800) without bit 3; also diskStart16 = 0xFFFF resolved via 0x0001.
        var entry1 = RawZipEntry(name: "Data descriptor sync.opus", method: 8, uncompressedData: opus1)
        entry1.localFlags = 0x0008
        entry1.centralFlags = 0x0800
        entry1.appendDataDescriptor = true
        entry1.forceZip64Extra = true
        entry1.diskStart16 = 0xFFFF

        // Entry 2: Local header has superfast deflate bits (0x0006) and no UTF-8 flag,
        // while Central Directory has 0x0800.
        var entry2 = RawZipEntry(name: "Flag difference check.opus", method: 8, uncompressedData: opus2)
        entry2.localFlags = 0x0006
        entry2.centralFlags = 0x0800
        entry2.forceZip64Extra = true

        let zipData = Self.buildZip(entries: [entry1, entry2], forceAllZip64Sentinels: true, comment: Data("zip64".utf8))
        let zipURL = f.root.appendingPathComponent("zip64-sentinels.zip")
        try zipData.write(to: zipURL)

        var summary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(zipURL, into: library, temporaryRoot: staging, summary: &summary)
        #expect(summary.imported == 2)
        #expect(summary.failed == 0)
        #expect(summary.unsupported == 0)
        let titles = Set(try LibraryScanner(root: library).scan().meetings.compactMap(\.title))
        #expect(titles.contains("Conformance vector 001"))
        #expect(titles.contains("Flag difference check"))
    }

    @Test func sparseZip64OverFourGigabytesCountsOversizedSingleEntryAsFailedAndImportsValidEntryPast4GiB() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let staging = f.root.appendingPathComponent("Temp")
        let validOpus = try Self.untitledPlainOpus(from: f)

        // Build a real sparse ZIP64 file on APFS:
        // Entry 1: Stored "oversized.opus" of size 4 GiB + 64 bytes (> UInt32.max, < 20 GB).
        // Entry 2: Valid "Beyond four gigabytes.opus" at localHeaderOffset > 4 GiB!
        let sparseZip = f.root.appendingPathComponent("sparse-over-4gib.zip")
        let fd = Darwin.open(sparseZip.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        #expect(fd >= 0)
        defer { Darwin.close(fd) }

        let oversizedLen: UInt64 = UInt64(UInt32.max) + 64
        let name1 = Data("oversized.opus".utf8)
        var lh1 = Data()
        var extra1Local = Data()
        extra1Local.appendTestU16LE(0x0001)
        extra1Local.appendTestU16LE(16)
        extra1Local.appendTestU64LE(oversizedLen)
        extra1Local.appendTestU64LE(oversizedLen)
        lh1.appendTestU32LE(0x0403_4b50)
        lh1.appendTestU16LE(45)
        lh1.appendTestU16LE(0x0800)
        lh1.appendTestU16LE(0) // Stored
        lh1.appendTestU16LE(0)
        lh1.appendTestU16LE(0x21)
        lh1.appendTestU32LE(0)
        lh1.appendTestU32LE(0xFFFF_FFFF)
        lh1.appendTestU32LE(0xFFFF_FFFF)
        lh1.appendTestU16LE(UInt16(name1.count))
        lh1.appendTestU16LE(UInt16(extra1Local.count))
        lh1.append(name1)
        lh1.append(extra1Local)
        Self.pwriteData(lh1, fd: fd, offset: 0)

        let offset2 = UInt64(lh1.count) + oversizedLen
        #expect(offset2 > UInt64(UInt32.max))

        let name2 = Data("Beyond four gigabytes.opus".utf8)
        let crc2 = RawZipEntry.crc32(validOpus)
        var lh2 = Data()
        lh2.appendTestU32LE(0x0403_4b50)
        lh2.appendTestU16LE(20)
        lh2.appendTestU16LE(0x0800)
        lh2.appendTestU16LE(0)
        lh2.appendTestU16LE(0)
        lh2.appendTestU16LE(0x21)
        lh2.appendTestU32LE(crc2)
        lh2.appendTestU32LE(UInt32(validOpus.count))
        lh2.appendTestU32LE(UInt32(validOpus.count))
        lh2.appendTestU16LE(UInt16(name2.count))
        lh2.appendTestU16LE(0)
        lh2.append(name2)
        lh2.append(validOpus)
        Self.pwriteData(lh2, fd: fd, offset: offset2)

        let cdOffset = offset2 + UInt64(lh2.count)
        var tail = Data()

        // CD 1 (64-bit sizes)
        var cd1Extra = Data()
        cd1Extra.appendTestU16LE(0x0001)
        cd1Extra.appendTestU16LE(16)
        cd1Extra.appendTestU64LE(oversizedLen)
        cd1Extra.appendTestU64LE(oversizedLen)
        tail.appendTestU32LE(0x0201_4b50)
        tail.appendTestU16LE((3 << 8) | 45)
        tail.appendTestU16LE(45)
        tail.appendTestU16LE(0x0800)
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0x21)
        tail.appendTestU32LE(0)
        tail.appendTestU32LE(0xFFFF_FFFF)
        tail.appendTestU32LE(0xFFFF_FFFF)
        tail.appendTestU16LE(UInt16(name1.count))
        tail.appendTestU16LE(UInt16(cd1Extra.count))
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0)
        tail.appendTestU32LE(UInt32(0o100644) << 16)
        tail.appendTestU32LE(0)
        tail.append(name1)
        tail.append(cd1Extra)

        // CD 2 (64-bit localHeaderOffset > 4 GiB!)
        var cd2Extra = Data()
        cd2Extra.appendTestU16LE(0x0001)
        cd2Extra.appendTestU16LE(8)
        cd2Extra.appendTestU64LE(offset2)
        tail.appendTestU32LE(0x0201_4b50)
        tail.appendTestU16LE((3 << 8) | 45)
        tail.appendTestU16LE(45)
        tail.appendTestU16LE(0x0800)
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0x21)
        tail.appendTestU32LE(crc2)
        tail.appendTestU32LE(UInt32(validOpus.count))
        tail.appendTestU32LE(UInt32(validOpus.count))
        tail.appendTestU16LE(UInt16(name2.count))
        tail.appendTestU16LE(UInt16(cd2Extra.count))
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0)
        tail.appendTestU32LE(UInt32(0o100644) << 16)
        tail.appendTestU32LE(0xFFFF_FFFF)
        tail.append(name2)
        tail.append(cd2Extra)

        let cdSize = UInt64(tail.count)
        let z64Offset = cdOffset + cdSize
        tail.appendTestU32LE(0x0606_4b50)
        tail.appendTestU64LE(44)
        tail.appendTestU16LE((3 << 8) | 45)
        tail.appendTestU16LE(45)
        tail.appendTestU32LE(0)
        tail.appendTestU32LE(0)
        tail.appendTestU64LE(2)
        tail.appendTestU64LE(2)
        tail.appendTestU64LE(cdSize)
        tail.appendTestU64LE(cdOffset)

        tail.appendTestU32LE(0x0706_4b50)
        tail.appendTestU32LE(0)
        tail.appendTestU64LE(z64Offset)
        tail.appendTestU32LE(1)

        tail.appendTestU32LE(0x0605_4b50)
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(0)
        tail.appendTestU16LE(2)
        tail.appendTestU16LE(2)
        tail.appendTestU32LE(UInt32(cdSize))
        tail.appendTestU32LE(0xFFFF_FFFF)
        tail.appendTestU16LE(0)

        Self.pwriteData(tail, fd: fd, offset: cdOffset)

        var summary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(sparseZip, into: library, temporaryRoot: staging, summary: &summary)
        #expect(summary.imported == 1)
        #expect(summary.failed == 1)
        #expect(summary.unsupported == 0)
        #expect(summary.lastSelected?.title == "Beyond four gigabytes")
    }

    // MARK: - 3. Encryption (PKWARE, Strong, WinZip AES method 99 & extra 0x9901)

    @Test func encryptedArchivesAreRefusedAcrossCentralAndLocalHeaders() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let validOpus = try Data(contentsOf: f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus"))

        var aesExtra = Data()
        aesExtra.appendTestU16LE(0x9901)
        aesExtra.appendTestU16LE(7)
        aesExtra.append(contentsOf: [0x02, 0x00, 0x41, 0x45, 0x03, 0x08, 0x00])

        var pkwareCentral = RawZipEntry(name: "enc.opus", method: 0, uncompressedData: validOpus)
        pkwareCentral.centralFlags |= 0x0001

        var strongCentral = RawZipEntry(name: "enc.opus", method: 0, uncompressedData: validOpus)
        strongCentral.centralFlags |= 0x0040

        var aesMethodCentral = RawZipEntry(name: "enc.opus", method: 0, uncompressedData: validOpus)
        aesMethodCentral.centralMethod = 99
        aesMethodCentral.localMethod = 99

        var aesExtraCentral = RawZipEntry(name: "enc.opus", method: 8, uncompressedData: validOpus)
        aesExtraCentral.centralExtra = aesExtra

        // Local-header-only encryption on second entry after clean first entry!
        var localOnlyAES = RawZipEntry(name: "enc2.opus", method: 8, uncompressedData: validOpus)
        localOnlyAES.localExtra = aesExtra

        var localOnlyBit0 = RawZipEntry(name: "enc3.opus", method: 0, uncompressedData: validOpus)
        localOnlyBit0.localFlags = 0x0001

        let cleanFirst = RawZipEntry(name: "clean.opus", method: 0, uncompressedData: validOpus)
        let cases: [[RawZipEntry]] = [
            [pkwareCentral],
            [strongCentral],
            [aesMethodCentral],
            [aesExtraCentral],
            [cleanFirst, localOnlyAES],
            [cleanFirst, localOnlyBit0],
        ]

        for (idx, entries) in cases.enumerated() {
            let zipURL = f.root.appendingPathComponent("encrypted-\(idx).zip")
            try Self.buildZip(entries: entries).write(to: zipURL)
            var summary = LibraryImportSummary()
            #expect(throws: ZipArchiveFailure.encrypted) {
                try ZipArchiveImport.importArchive(zipURL, into: library, summary: &summary)
            }
            #expect(!FileManager.default.fileExists(atPath: library.path))
        }
    }

    // MARK: - 4. Path Safety, Colons & Backslashes, Basename Reduction, and Staging Isolation

    @Test func unsafePathsRefuseWholeArchiveWhileColonsAndBackslashesReduceToBaseNamesInPrivateStaging() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let staging = f.root.appendingPathComponent("StagingCheck")
        let plainOpus = try Self.untitledPlainOpus(from: f)
        let cleanFirst = RawZipEntry(name: "clean.opus", method: 0, uncompressedData: plainOpus)

        let unsafeNames = [
            "/etc/passwd.opus",
            "\\Windows\\System32\\evil.opus",
            "../escape.opus",
            "sub/../../escape.opus",
            "sub\\..\\escape.opus",
            "null\0byte.opus",
        ]
        for (idx, bad) in unsafeNames.enumerated() {
            // Unsafe in Central Directory
            let cdZip = f.root.appendingPathComponent("unsafe-cd-\(idx).zip")
            try Self.buildZip(entries: [cleanFirst, RawZipEntry(name: bad, method: 0, uncompressedData: plainOpus)]).write(to: cdZip)
            var s = LibraryImportSummary()
            #expect(throws: ZipArchiveFailure.unsafePaths) {
                try ZipArchiveImport.importArchive(cdZip, into: library, temporaryRoot: staging, summary: &s)
            }
            // Unsafe only in Local Header
            var localTrick = RawZipEntry(name: "harmless.opus", method: 0, uncompressedData: plainOpus)
            localTrick.localName = Data(bad.utf8)
            let lhZip = f.root.appendingPathComponent("unsafe-lh-\(idx).zip")
            try Self.buildZip(entries: [cleanFirst, localTrick]).write(to: lhZip)
            #expect(throws: ZipArchiveFailure.unsafePaths) {
                try ZipArchiveImport.importArchive(lhZip, into: library, temporaryRoot: staging, summary: &s)
            }
            #expect(!FileManager.default.fileExists(atPath: library.path))
        }

        // Allowed names: colons in filenames, Windows "\" separators, single "." or "..nottraversal.." segments.
        let allowed = [
            RawZipEntry(name: "Exports\\2026\\14:30:00 Budget: Review.opus", method: 8, uncompressedData: plainOpus),
            RawZipEntry(name: "Team/..notes../Follow-up: Q&A.ogg", method: 0, uncompressedData: try Data(contentsOf: f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus"))),
        ]
        let allowedZip = f.root.appendingPathComponent("allowed-paths.zip")
        try Self.buildZip(entries: allowed).write(to: allowedZip)

        var summary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(allowedZip, into: library, temporaryRoot: staging, summary: &summary)
        #expect(summary.imported == 2)
        #expect(summary.failed == 0)
        #expect(summary.unsupported == 0)

        let scanned = try LibraryScanner(root: library).scan().meetings
        #expect(scanned.count == 2)
        #expect(scanned.contains { $0.title == "14:30:00 Budget: Review" })
        // Private staging folder name must NEVER leak into received.originalFolderName.
        #expect(scanned.allSatisfy { $0.received?.originalFolderName == nil })
        // Staging root must have zero leftover subdirectories or files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    // MARK: - 5. Finder Sidecars, Directories, Nested Archives, Empty & Damaged

    @Test func finderSidecarsNestedArchivesEmptyAndDamagedArchivesClassifyExactCounts() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let staging = f.root.appendingPathComponent("Temp")
        let opusBytes = try Self.untitledPlainOpus(from: f)

        let nestedZipBytes = Self.buildZip(entries: [RawZipEntry(name: "inner.opus", method: 0, uncompressedData: opusBytes)])
        var badCRC = RawZipEntry(name: "Folder/bad-crc.opus", method: 0, uncompressedData: opusBytes)
        badCRC.centralCRC = (badCRC.centralCRC ?? 0) ^ 0xDEAD_BEEF
        badCRC.localCRC = badCRC.centralCRC

        let finderEntries: [RawZipEntry] = [
            RawZipEntry(name: "Folder/", isDirectory: true),
            RawZipEntry(name: "__MACOSX/", isDirectory: true),
            RawZipEntry(name: "WinFolder\\", isDirectory: true),
            RawZipEntry(name: "__MACOSX/Folder/._Design review.opus", method: 0, uncompressedData: Data([0x00, 0x05, 0x16, 0x07])),
            RawZipEntry(name: "Folder/._Design review.opus", method: 0, uncompressedData: Data([0x00, 0x05, 0x16, 0x07])),
            RawZipEntry(name: "Folder/.DS_Store", method: 0, uncompressedData: Data("dsstore".utf8)),
            RawZipEntry(name: "Folder/nested-archive.zip", method: 0, uncompressedData: nestedZipBytes),
            RawZipEntry(name: "Folder/agenda.pdf", method: 0, uncompressedData: Data("pdf".utf8)),
            RawZipEntry(name: "Folder/Design review.opus", method: 8, uncompressedData: opusBytes),
            RawZipEntry(name: "Folder/corrupt.opus", method: 0, uncompressedData: Data("not-an-ogg-stream".utf8)),
            badCRC,
        ]
        let finderZip = f.root.appendingPathComponent("finder.zip")
        try Self.buildZip(entries: finderEntries).write(to: finderZip)

        var summary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(finderZip, into: library, temporaryRoot: staging, summary: &summary)
        #expect(summary.imported == 1)
        #expect(summary.unsupported == 5) // __MACOSX/._, Folder/._, .DS_Store, nested.zip, agenda.pdf (3 dirs ignored)
        #expect(summary.failed == 2) // corrupt.opus + bad-crc.opus
        #expect(summary.duplicates == 0)
        #expect(summary.lastSelected?.title == "Design review")

        // Empty / no-supported-audio archive (only directories + Finder sidecar + txt) -> ZipArchiveFailure.empty
        let emptyZip = f.root.appendingPathComponent("empty.zip")
        try Self.buildZip(entries: [
            RawZipEntry(name: "EmptyFolder/", isDirectory: true),
            RawZipEntry(name: "__MACOSX/._Meeting.opus", method: 0, uncompressedData: Data([1, 2, 3])),
            RawZipEntry(name: "EmptyFolder/notes.txt", method: 0, uncompressedData: Data("hello".utf8)),
        ]).write(to: emptyZip)
        var emptySummary = LibraryImportSummary()
        #expect(throws: ZipArchiveFailure.empty) {
            try ZipArchiveImport.importArchive(emptyZip, into: library, temporaryRoot: staging, summary: &emptySummary)
        }

        // Damaged / non-ZIP / truncated archive -> ZipArchiveFailure.damaged
        let notZip = f.root.appendingPathComponent("damaged.zip")
        try Data("definitely not a zip file at all".utf8).write(to: notZip)
        #expect(throws: ZipArchiveFailure.damaged) {
            try ZipArchiveImport.importArchive(notZip, into: library, temporaryRoot: staging, summary: &emptySummary)
        }
        let truncatedZip = f.root.appendingPathComponent("truncated.zip")
        try Self.buildZip(entries: [RawZipEntry(name: "a.opus", method: 0, uncompressedData: opusBytes)]).dropLast(8).write(to: truncatedZip)
        #expect(throws: ZipArchiveFailure.damaged) {
            try ZipArchiveImport.importArchive(truncatedZip, into: library, temporaryRoot: staging, summary: &emptySummary)
        }
    }

    // MARK: - 6. Multi-file Batch, Duplicate Preservation, Cancellation & Localization

    @Test func batchImportDeduplicatesPreservesEditsCancelsCleanlyAndRendersLocalizedCopy() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let staging = f.root.appendingPathComponent("Temp")
        let doc1Source = f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus")
        let doc2Source = f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus")

        // Pre-import doc1 and edit its title & notes so duplicate detection must preserve them.
        let existing = try LibraryImport.copy(doc1Source, into: library)
        try MeetingMetadataWriter(directory: existing.folder, id: existing.id).transaction {
            $0["title"] = "Edited before batch"
            $0["titleSource"] = "user"
            $0["notes"] = [["atMs": 50, "text": "Keep my note"]]
        }

        let copyOfDoc1 = f.root.appendingPathComponent("Duplicate copy.opus")
        try FileManager.default.copyItem(at: doc1Source, to: copyOfDoc1)
        let freshDoc2 = f.root.appendingPathComponent("Second meeting.opus")
        try Self.untitledPlainOpus(from: f).write(to: freshDoc2)
        let unsupportedTxt = f.root.appendingPathComponent("Notes.txt")
        try Data("notes".utf8).write(to: unsupportedTxt)
        let brokenOpus = f.root.appendingPathComponent("Broken.opus")
        try Data("corrupt-bytes".utf8).write(to: brokenOpus)

        var batchSummary = LibraryImportSummary()
        var progressEvents: [(Int, Int)] = []
        _ = try LibraryBatchImport.importURLs(
            [copyOfDoc1, freshDoc2, unsupportedTxt, brokenOpus],
            into: library,
            temporaryRoot: staging,
            summary: &batchSummary,
            onProgress: { done, total in progressEvents.append((done, total)) }
        )
        #expect(batchSummary.imported == 1)
        #expect(batchSummary.duplicates == 1)
        #expect(batchSummary.unsupported == 1)
        #expect(batchSummary.failed == 1)
        #expect(batchSummary.lastSelected?.title == "Second meeting")
        #expect(!progressEvents.isEmpty)

        // Verify pre-existing duplicate kept its user title and notes.
        let refreshedExisting = try #require(LibraryScanner(root: library).meeting(at: existing.folder))
        #expect(refreshedExisting.title == "Edited before batch")
        #expect(refreshedExisting.notes.map(\.text) == ["Keep my note"])

        let renderedEnglish = batchSummary.rendered(language: .en, locale: Locale(identifier: "en_US"))
        #expect(renderedEnglish == "Imported 1 · Skipped 1 duplicate · Ignored 1 unsupported file · 1 file could not be imported")

        // Deterministic mid-import cancellation: cancel as soon as item 2 starts after item 1 completes!
        let cancelLib = f.root.appendingPathComponent("CancelLibrary")
        let zipForCancel = f.root.appendingPathComponent("two-items.zip")
        try Self.buildZip(entries: [
            RawZipEntry(name: "First item.opus", method: 8, uncompressedData: Data(contentsOf: doc1Source)),
            RawZipEntry(name: "Second item.opus", method: 8, uncompressedData: Data(contentsOf: doc2Source)),
        ]).write(to: zipForCancel)

        var cancelSummary = LibraryImportSummary()
        var streamedPartial = LibraryImportSummary()
        var cancelFlag = false
        #expect(throws: CancellationError.self) {
            try LibraryBatchImport.importURLs(
                [zipForCancel],
                into: cancelLib,
                temporaryRoot: staging,
                summary: &cancelSummary,
                onPartialSummary: { streamedPartial = $0 },
                onProgress: { done, _ in
                    if done == 2 { cancelFlag = true }
                },
                shouldCancel: { cancelFlag }
            )
        }
        #expect(cancelSummary.imported == 1 && streamedPartial.imported == 1)
        #expect(cancelSummary.failed == 0 && streamedPartial.failed == 0) // Cancelled item is NOT failed!
        #expect(try LibraryScanner(root: cancelLib).scan().meetings.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)

        cancelSummary.cancelled = true
        let cancelledCopy = cancelSummary.rendered(language: .en, locale: Locale(identifier: "en_US"))
        #expect(cancelledCopy == "Import cancelled · Imported 1")

        // Verify all 16 D96 catalog keys and {done}/{total} regional number formatting across all 6 languages.
        let d96IDs = [
            "import.filter.cassiniAndZip", "import.progress",
            "import.summary.imported", "import.summary.duplicates", "import.summary.unsupported", "import.summary.failed",
            "import.cancelled",
            "import.zip.failed.damaged", "import.zip.failed.encrypted", "import.zip.failed.unsafePaths",
            "import.zip.failed.tooLarge", "import.zip.failed.empty",
            "export.zip.all", "export.zip.selected", "export.zip.progress", "export.zip.done",
        ]
        for language in CassiniLanguage.allCases {
            for id in d96IDs {
                let text = LibraryLocalization.shared.text(
                    id,
                    ["n": "2", "done": "1234", "total": "2000"],
                    language: language,
                    locale: Locale(identifier: language.rawValue)
                )
                #expect(!text.isEmpty && !text.contains("{"))
            }
        }
        #expect(
            LibraryLocalization.shared.text("import.progress", ["done": "1234", "total": "2000"], language: .en, locale: Locale(identifier: "en_US"))
                == "Importing 1,234 of 2,000…"
        )
        #expect(
            LibraryLocalization.shared.text("export.zip.progress", ["done": "1234", "total": "2000"], language: .fr, locale: Locale(identifier: "fr_FR"))
                == "Exportation 1\u{202f}234 sur 2\u{202f}000…"
        )
    }

    private static func pwriteData(_ data: Data, fd: Int32, offset: UInt64) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !raw.isEmpty else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.pwrite(fd, base.advanced(by: written), raw.count - written, off_t(offset) + off_t(written))
                precondition(n > 0)
                written += n
            }
        }
    }
}

private extension Data {
    mutating func appendTestU16LE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendTestU32LE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendTestU64LE(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
