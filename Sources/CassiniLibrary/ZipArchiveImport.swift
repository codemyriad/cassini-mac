// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import zlib

public enum ZipArchiveFailure: Error, Equatable, Sendable {
    case damaged
    case encrypted
    case unsafePaths
    case tooLarge
    case empty

    public var localizationID: String {
        switch self {
        case .damaged: return "import.zip.failed.damaged"
        case .encrypted: return "import.zip.failed.encrypted"
        case .unsafePaths: return "import.zip.failed.unsafePaths"
        case .tooLarge: return "import.zip.failed.tooLarge"
        case .empty: return "import.zip.failed.empty"
        }
    }
}

/// D96 streaming ZIP32/ZIP64 reader and batch importer.
/// Enforces archive limits on both the directory and the actual bytes read,
/// never extracts using archive entry names on disk, and isolates staging to a 0700 folder.
public enum ZipArchiveImport {
    public static let maxEntries = 2_000
    public static let maxTotalUncompressedBytes: UInt64 = 20_000_000_000
    public static let maxCompressionRatio: UInt64 = 100
    public static let maxSingleEntryBytes: UInt64 = UInt64(UInt32.max)
    private static let chunkSize = 64 * 1024

    public static func exceedsCompressionRatio(uncompressed: UInt64, compressed: UInt64) -> Bool {
        if uncompressed == 0 { return false }
        if compressed == 0 { return true }
        return (uncompressed - 1) / maxCompressionRatio >= compressed
    }

    public static func isUnsafeArchivePath(_ name: String) -> Bool {
        if name.contains("\0") || name.hasPrefix("/") || name.hasPrefix("\\") {
            return true
        }
        let segments = name.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return segments.contains("..")
    }

    private enum EntryKind {
        case directory
        case unsupported
        case supported(baseName: String, titleFallback: String)
    }

    private struct ArchiveEntry {
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        var dataOffset: UInt64 = 0
        var localMethod: UInt16 = 0
        let kind: EntryKind
    }

    public static func supportedEntryCount(in archiveURL: URL, shouldCancel: () -> Bool = { false }) throws -> Int {
        let (fd, identity) = try openArchiveFD(archiveURL)
        defer { Darwin.close(fd) }
        let entries = try readAndValidateDirectory(fd: fd, fileSize: UInt64(identity.size), shouldCancel: shouldCancel)
        return entries.reduce(into: 0) { count, entry in
            if case .supported = entry.kind { count += 1 }
        }
    }

    @discardableResult
    public static func importArchive(
        _ archiveURL: URL,
        into root: URL,
        additionalRoots: [URL] = [],
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        session: LibraryImport.BatchSession? = nil,
        summary: inout LibraryImportSummary,
        onPartialSummary: (LibraryImportSummary) -> Void = { _ in },
        onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
        shouldCancel: () -> Bool = { false }
    ) throws -> LibraryImportSummary {
        let batchSession = session ?? LibraryImport.BatchSession(root: root, additionalRoots: additionalRoots)
        let (fd, identity) = try openArchiveFD(archiveURL)
        defer { Darwin.close(fd) }

        let entries = try readAndValidateDirectory(fd: fd, fileSize: UInt64(identity.size), shouldCancel: shouldCancel)
        let supportedTotal = entries.reduce(into: 0) { count, entry in
            if case .supported = entry.kind { count += 1 }
        }
        guard supportedTotal > 0 else {
            throw ZipArchiveFailure.empty
        }

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stagingDir = temporaryRoot.appendingPathComponent("CassiniZipStage-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let stagedFile = stagingDir.appendingPathComponent("entry.opus")

        let initialSummary = summary
        var createdImports: [(folder: URL, digest: String?)] = []
        var cumulativeActualUncompressed: UInt64 = 0
        var supportedDone = 0

        do {
            for entry in entries {
                if shouldCancel() { throw CancellationError() }

                switch entry.kind {
                case .directory:
                    continue

                case .unsupported:
                    try verifyUnsupportedRuntimeBytes(
                        fd: fd,
                        entry: entry,
                        cumulativeActualUncompressed: &cumulativeActualUncompressed,
                        shouldCancel: shouldCancel
                    )
                    summary.unsupported += 1
                    onPartialSummary(summary)

                case .supported(_, let titleFallback):
                    supportedDone += 1
                    onProgress(supportedDone, supportedTotal)
                    try? FileManager.default.removeItem(at: stagedFile)
                    defer { try? FileManager.default.removeItem(at: stagedFile) }

                    guard entry.localMethod == entry.method, entry.method == 0 || entry.method == 8 else {
                        summary.failed += 1
                        onPartialSummary(summary)
                        continue
                    }

                    if entry.uncompressedSize > maxSingleEntryBytes {
                        try drainOversizedSupportedEntry(
                            fd: fd,
                            entry: entry,
                            cumulativeActualUncompressed: &cumulativeActualUncompressed,
                            shouldCancel: shouldCancel
                        )
                        summary.failed += 1
                        onPartialSummary(summary)
                        continue
                    }

                    let extractedOK = try extractSupportedEntry(
                        fd: fd,
                        entry: entry,
                        to: stagedFile,
                        cumulativeActualUncompressed: &cumulativeActualUncompressed,
                        shouldCancel: shouldCancel
                    )
                    guard extractedOK else {
                        summary.failed += 1
                        onPartialSummary(summary)
                        continue
                    }

                    if shouldCancel() { throw CancellationError() }

                    do {
                        let outcome = try LibraryImport.copyWithOutcome(
                            stagedFile,
                            into: root,
                            additionalRoots: additionalRoots,
                            titleFallback: titleFallback,
                            includeParentFolder: false,
                            session: batchSession,
                            shouldCancel: shouldCancel
                        )
                        switch outcome {
                        case .imported(let meeting):
                            createdImports.append((meeting.folder, meeting.received?.sha256))
                            summary.imported += 1
                            summary.lastSelected = meeting
                        case .duplicate(let meeting):
                            summary.duplicates += 1
                            if summary.lastSelected == nil { summary.lastSelected = meeting }
                        }
                        onPartialSummary(summary)
                    } catch let cancel as CancellationError {
                        throw cancel
                    } catch {
                        summary.failed += 1
                        onPartialSummary(summary)
                    }
                }
            }
            return summary
        } catch let archiveFailure as ZipArchiveFailure {
            for created in createdImports {
                LibraryImport.rollbackImported(folder: created.folder, digest: created.digest, session: batchSession)
            }
            summary = initialSummary
            onPartialSummary(summary)
            throw archiveFailure
        }
    }

    // MARK: - Directory & Header Preflight

    private static func openArchiveFD(_ url: URL) throws -> (Int32, FileKey) {
        do {
            let (fd, key) = try openRegular(url)
            guard key.size >= 22 else {
                Darwin.close(fd)
                throw ZipArchiveFailure.damaged
            }
            return (fd, key)
        } catch let failure as ZipArchiveFailure {
            throw failure
        } catch {
            throw ZipArchiveFailure.damaged
        }
    }

    private static func readAndValidateDirectory(
        fd: Int32,
        fileSize: UInt64,
        shouldCancel: () -> Bool
    ) throws -> [ArchiveEntry] {
        let directoryLocation = try locateCentralDirectory(fd: fd, fileSize: fileSize)
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(min(directoryLocation.totalEntries, UInt64(maxEntries + 64))))

        var reader = BoundedFileReader(
            fd: fd,
            startOffset: directoryLocation.offset,
            endOffset: directoryLocation.offset + directoryLocation.size
        )
        var nonDirectoryCount = 0
        var totalDeclaredUncompressed: UInt64 = 0

        var index: UInt64 = 0
        while index < directoryLocation.totalEntries {
            if (index & 0xFF) == 0 && shouldCancel() { throw CancellationError() }
            let header = try reader.readExact(46)
            guard header.u32LE(at: 0) == 0x0201_4b50 else {
                throw ZipArchiveFailure.damaged
            }

            let flags = header.u16LE(at: 8)
            let method = header.u16LE(at: 10)
            let crc = header.u32LE(at: 16)
            let compressed32 = header.u32LE(at: 20)
            let uncompressed32 = header.u32LE(at: 24)
            let nameLen = Int(header.u16LE(at: 28))
            let extraLen = Int(header.u16LE(at: 30))
            let commentLen = Int(header.u16LE(at: 32))
            let diskStart16 = header.u16LE(at: 34)
            let externalAttrs = header.u32LE(at: 38)
            let localOffset32 = header.u32LE(at: 42)

            guard nameLen > 0 else { throw ZipArchiveFailure.damaged }
            let nameBytes = try reader.readExact(nameLen)
            let extraBytes = try reader.readExact(extraLen)
            try reader.skipExact(commentLen)

            if isEncryptedHeader(flags: flags, method: method, extra: extraBytes) {
                throw ZipArchiveFailure.encrypted
            }
            if nameBytes.contains(0) {
                throw ZipArchiveFailure.unsafePaths
            }
            let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1)!
            if isUnsafeArchivePath(name) {
                throw ZipArchiveFailure.unsafePaths
            }

            var uncompressedSize = UInt64(uncompressed32)
            var compressedSize = UInt64(compressed32)
            var localHeaderOffset = UInt64(localOffset32)
            var diskStart = UInt32(diskStart16)

            if uncompressed32 == 0xFFFF_FFFF || compressed32 == 0xFFFF_FFFF || localOffset32 == 0xFFFF_FFFF || diskStart16 == 0xFFFF {
                guard let zip64Payload = try findExtraField(id: 0x0001, in: extraBytes, strict: true) else {
                    throw ZipArchiveFailure.damaged
                }
                var cursor = 0
                if uncompressed32 == 0xFFFF_FFFF {
                    guard cursor + 8 <= zip64Payload.count else { throw ZipArchiveFailure.damaged }
                    uncompressedSize = zip64Payload.u64LE(at: cursor)
                    cursor += 8
                }
                if compressed32 == 0xFFFF_FFFF {
                    guard cursor + 8 <= zip64Payload.count else { throw ZipArchiveFailure.damaged }
                    compressedSize = zip64Payload.u64LE(at: cursor)
                    cursor += 8
                }
                if localOffset32 == 0xFFFF_FFFF {
                    guard cursor + 8 <= zip64Payload.count else { throw ZipArchiveFailure.damaged }
                    localHeaderOffset = zip64Payload.u64LE(at: cursor)
                    cursor += 8
                }
                if diskStart16 == 0xFFFF {
                    guard cursor + 4 <= zip64Payload.count else { throw ZipArchiveFailure.damaged }
                    diskStart = zip64Payload.u32LE(at: cursor)
                    cursor += 4
                }
            }
            guard diskStart == 0 else { throw ZipArchiveFailure.damaged }

            let kind = classifyEntry(name: name, uncompressedSize: uncompressedSize, externalAttributes: externalAttrs)
            if case .directory = kind {
                guard localHeaderOffset <= directoryLocation.offset,
                      directoryLocation.offset - localHeaderOffset >= 30 else {
                    throw ZipArchiveFailure.damaged
                }
                entries.append(ArchiveEntry(
                    flags: flags,
                    method: method,
                    crc32: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset,
                    kind: kind
                ))
                index += 1
                continue
            }

            nonDirectoryCount += 1
            if nonDirectoryCount > maxEntries {
                throw ZipArchiveFailure.tooLarge
            }
            let (nextTotal, overflow) = totalDeclaredUncompressed.addingReportingOverflow(uncompressedSize)
            if overflow || nextTotal > maxTotalUncompressedBytes {
                throw ZipArchiveFailure.tooLarge
            }
            totalDeclaredUncompressed = nextTotal

            if exceedsCompressionRatio(uncompressed: uncompressedSize, compressed: compressedSize) {
                throw ZipArchiveFailure.tooLarge
            }

            guard localHeaderOffset <= directoryLocation.offset,
                  directoryLocation.offset - localHeaderOffset >= 30 else {
                throw ZipArchiveFailure.damaged
            }

            entries.append(ArchiveEntry(
                flags: flags,
                method: method,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                kind: kind
            ))
            index += 1
        }

        guard reader.isAtEnd else { throw ZipArchiveFailure.damaged }

        for i in entries.indices {
            if (i & 0xFF) == 0 && shouldCancel() { throw CancellationError() }
            let entry = entries[i]
            let local = try preadExact(fd: fd, offset: entry.localHeaderOffset, count: 30)
            guard local.u32LE(at: 0) == 0x0403_4b50 else {
                throw ZipArchiveFailure.damaged
            }
            let localFlags = local.u16LE(at: 6)
            let localMethod = local.u16LE(at: 8)
            let localCompressed32 = local.u32LE(at: 18)
            let localUncompressed32 = local.u32LE(at: 22)
            let localNameLen = Int(local.u16LE(at: 26))
            let localExtraLen = Int(local.u16LE(at: 28))

            let variableLen = UInt64(localNameLen) + UInt64(localExtraLen)
            guard variableLen <= directoryLocation.offset - entry.localHeaderOffset - 30 else {
                throw ZipArchiveFailure.damaged
            }
            let variable = localNameLen + localExtraLen > 0
                ? try preadExact(fd: fd, offset: entry.localHeaderOffset + 30, count: localNameLen + localExtraLen)
                : Data()
            let localNameBytes = variable.prefix(localNameLen)
            let localExtraBytes = Data(variable.dropFirst(localNameLen))

            if isEncryptedHeader(flags: localFlags, method: localMethod, extra: localExtraBytes) {
                throw ZipArchiveFailure.encrypted
            }
            if !localNameBytes.isEmpty {
                if localNameBytes.contains(0) {
                    throw ZipArchiveFailure.unsafePaths
                }
                let localName = String(data: localNameBytes, encoding: .utf8) ?? String(data: localNameBytes, encoding: .isoLatin1)!
                if isUnsafeArchivePath(localName) {
                    throw ZipArchiveFailure.unsafePaths
                }
            }

            if (localFlags & 0x0008) == 0 && !(localCompressed32 == 0 && localUncompressed32 == 0) {
                var lhUncompressed = UInt64(localUncompressed32)
                var lhCompressed = UInt64(localCompressed32)
                if localUncompressed32 == 0xFFFF_FFFF || localCompressed32 == 0xFFFF_FFFF {
                    if let payload = try findExtraField(id: 0x0001, in: localExtraBytes, strict: false), payload.count >= 16 {
                        lhUncompressed = payload.u64LE(at: 0)
                        lhCompressed = payload.u64LE(at: 8)
                    }
                }
                if exceedsCompressionRatio(uncompressed: lhUncompressed, compressed: lhCompressed) {
                    throw ZipArchiveFailure.tooLarge
                }
            }

            let dataOffset = entry.localHeaderOffset + 30 + variableLen
            guard entry.compressedSize <= directoryLocation.offset - dataOffset else {
                throw ZipArchiveFailure.damaged
            }
            entries[i].dataOffset = dataOffset
            entries[i].localMethod = localMethod
        }

        return entries
    }

    private struct DirectoryLocation {
        let totalEntries: UInt64
        let size: UInt64
        let offset: UInt64
    }

    private static func locateCentralDirectory(fd: Int32, fileSize: UInt64) throws -> DirectoryLocation {
        let maxTail: UInt64 = 22 + 65_535
        let tailCount = Int(min(fileSize, maxTail))
        let tailStart = fileSize - UInt64(tailCount)
        let tail = try preadExact(fd: fd, offset: tailStart, count: tailCount)

        var foundPos: Int?
        var pos = tailCount - 22
        while pos >= 0 {
            if tail.u32LE(at: pos) == 0x0605_4b50 {
                let commentLen = Int(tail.u16LE(at: pos + 20))
                if pos + 22 + commentLen == tailCount {
                    foundPos = pos
                    break
                }
            }
            pos -= 1
        }
        guard let eocdPos = foundPos else {
            throw ZipArchiveFailure.damaged
        }

        let eocdOffset = tailStart + UInt64(eocdPos)
        let diskNumber = tail.u16LE(at: eocdPos + 4)
        let centralDirDisk = tail.u16LE(at: eocdPos + 6)
        let entriesOnDisk = tail.u16LE(at: eocdPos + 8)
        let totalEntries16 = tail.u16LE(at: eocdPos + 10)
        let centralDirSize32 = tail.u32LE(at: eocdPos + 12)
        let centralDirOffset32 = tail.u32LE(at: eocdPos + 16)

        let hasZip64Sentinel =
            diskNumber == 0xFFFF ||
            centralDirDisk == 0xFFFF ||
            entriesOnDisk == 0xFFFF ||
            totalEntries16 == 0xFFFF ||
            centralDirSize32 == 0xFFFF_FFFF ||
            centralDirOffset32 == 0xFFFF_FFFF

        var locatorData: Data?
        if eocdOffset >= 20 {
            let candidate = try preadExact(fd: fd, offset: eocdOffset - 20, count: 20)
            if candidate.u32LE(at: 0) == 0x0706_4b50 {
                locatorData = candidate
            }
        }

        if hasZip64Sentinel && locatorData == nil {
            throw ZipArchiveFailure.damaged
        }

        if let locator = locatorData {
            if diskNumber != 0xFFFF && diskNumber != 0 { throw ZipArchiveFailure.damaged }
            if centralDirDisk != 0xFFFF && centralDirDisk != 0 { throw ZipArchiveFailure.damaged }

            let zip64Disk = locator.u32LE(at: 4)
            let zip64EOCDOffset = locator.u64LE(at: 8)
            let totalDisks = locator.u32LE(at: 16)
            guard zip64Disk == 0, totalDisks == 0 || totalDisks == 1 else {
                throw ZipArchiveFailure.damaged
            }
            let locatorOffset = eocdOffset - 20
            guard zip64EOCDOffset <= locatorOffset, locatorOffset - zip64EOCDOffset >= 56 else {
                throw ZipArchiveFailure.damaged
            }

            let z64 = try preadExact(fd: fd, offset: zip64EOCDOffset, count: 56)
            guard z64.u32LE(at: 0) == 0x0606_4b50 else {
                throw ZipArchiveFailure.damaged
            }
            let recordSize = z64.u64LE(at: 4)
            guard recordSize >= 44, recordSize <= locatorOffset - zip64EOCDOffset - 12 else {
                throw ZipArchiveFailure.damaged
            }
            let zDisk = z64.u32LE(at: 16)
            let zCDDisk = z64.u32LE(at: 20)
            let zEntriesOnDisk = z64.u64LE(at: 24)
            let zTotalEntries = z64.u64LE(at: 32)
            let zCDSize = z64.u64LE(at: 40)
            let zCDOffset = z64.u64LE(at: 48)

            guard zDisk == 0, zCDDisk == 0, zEntriesOnDisk == zTotalEntries else {
                throw ZipArchiveFailure.damaged
            }
            if entriesOnDisk != 0xFFFF && UInt64(entriesOnDisk) != zEntriesOnDisk { throw ZipArchiveFailure.damaged }
            if totalEntries16 != 0xFFFF && UInt64(totalEntries16) != zTotalEntries { throw ZipArchiveFailure.damaged }
            if centralDirSize32 != 0xFFFF_FFFF && UInt64(centralDirSize32) != zCDSize { throw ZipArchiveFailure.damaged }
            if centralDirOffset32 != 0xFFFF_FFFF && UInt64(centralDirOffset32) != zCDOffset { throw ZipArchiveFailure.damaged }

            guard zCDOffset <= zip64EOCDOffset, zCDSize <= zip64EOCDOffset - zCDOffset else {
                throw ZipArchiveFailure.damaged
            }
            return DirectoryLocation(totalEntries: zTotalEntries, size: zCDSize, offset: zCDOffset)
        } else {
            guard diskNumber == 0, centralDirDisk == 0, entriesOnDisk == totalEntries16 else {
                throw ZipArchiveFailure.damaged
            }
            let offset = UInt64(centralDirOffset32)
            let size = UInt64(centralDirSize32)
            guard offset <= eocdOffset, size <= eocdOffset - offset else {
                throw ZipArchiveFailure.damaged
            }
            return DirectoryLocation(totalEntries: UInt64(totalEntries16), size: size, offset: offset)
        }
    }

    private static func isEncryptedHeader(flags: UInt16, method: UInt16, extra: Data) -> Bool {
        if (flags & 0x0001) != 0 || (flags & 0x0040) != 0 || method == 99 {
            return true
        }
        return (try? findExtraField(id: 0x9901, in: extra, strict: false)) != nil
    }

    private static func findExtraField(id targetID: UInt16, in extra: Data, strict: Bool) throws -> Data? {
        var pos = 0
        while pos + 4 <= extra.count {
            let headerID = extra.u16LE(at: pos)
            let size = Int(extra.u16LE(at: pos + 2))
            guard pos + 4 + size <= extra.count else {
                if headerID == targetID || strict { throw ZipArchiveFailure.damaged }
                return nil
            }
            if headerID == targetID {
                return Data(extra[(pos + 4)..<(pos + 4 + size)])
            }
            pos += 4 + size
        }
        return nil
    }

    private static func classifyEntry(name: String, uncompressedSize: UInt64, externalAttributes: UInt32) -> EntryKind {
        if name.hasSuffix("/") || name.hasSuffix("\\") {
            return .directory
        }
        let unixMode = (externalAttributes >> 16) & UInt32(S_IFMT)
        if uncompressedSize == 0 && unixMode == UInt32(S_IFDIR) {
            return .directory
        }
        let segments = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let baseName = segments.last, !baseName.isEmpty, baseName != "." else {
            return .directory
        }
        if segments.contains("__MACOSX") || baseName.hasPrefix("._") || baseName == ".DS_Store" {
            return .unsupported
        }
        let nsBase = baseName as NSString
        let ext = nsBase.pathExtension.lowercased()
        guard LibraryImport.supportedAudioExtensions.contains(ext) else {
            return .unsupported
        }
        let stem = nsBase.deletingPathExtension
        return .supported(baseName: baseName, titleFallback: stem)
    }

    // MARK: - Streaming Extraction & Runtime Byte Limits

    private static func addRuntimeBytes(_ delta: UInt64, to total: inout UInt64) throws {
        let (next, overflow) = total.addingReportingOverflow(delta)
        if overflow || next > maxTotalUncompressedBytes {
            throw ZipArchiveFailure.tooLarge
        }
        total = next
    }

    private static func verifyUnsupportedRuntimeBytes(
        fd: Int32,
        entry: ArchiveEntry,
        cumulativeActualUncompressed: inout UInt64,
        shouldCancel: () -> Bool
    ) throws {
        if entry.method == 0 {
            try addRuntimeBytes(max(entry.compressedSize, entry.uncompressedSize), to: &cumulativeActualUncompressed)
        } else if entry.method == 8 && entry.compressedSize > 0 {
            _ = try streamDeflate(
                fd: fd,
                entry: entry,
                destinationFD: nil,
                cumulativeActualUncompressed: &cumulativeActualUncompressed,
                shouldCancel: shouldCancel
            )
        } else {
            try addRuntimeBytes(entry.uncompressedSize, to: &cumulativeActualUncompressed)
        }
    }

    private static func drainOversizedSupportedEntry(
        fd: Int32,
        entry: ArchiveEntry,
        cumulativeActualUncompressed: inout UInt64,
        shouldCancel: () -> Bool
    ) throws {
        if entry.method == 8 && entry.compressedSize > 0 {
            _ = try streamDeflate(
                fd: fd,
                entry: entry,
                destinationFD: nil,
                cumulativeActualUncompressed: &cumulativeActualUncompressed,
                shouldCancel: shouldCancel
            )
        } else {
            try addRuntimeBytes(entry.uncompressedSize, to: &cumulativeActualUncompressed)
        }
    }

    private static func extractSupportedEntry(
        fd: Int32,
        entry: ArchiveEntry,
        to stagedURL: URL,
        cumulativeActualUncompressed: inout UInt64,
        shouldCancel: () -> Bool
    ) throws -> Bool {
        let outFD = Darwin.open(stagedURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outFD >= 0 else { return false }
        var outOpen = true
        defer { if outOpen { Darwin.close(outFD) } }

        if entry.method == 0 {
            guard entry.compressedSize == entry.uncompressedSize else {
                try addRuntimeBytes(entry.compressedSize, to: &cumulativeActualUncompressed)
                return false
            }
            var remaining = entry.compressedSize
            var offset = entry.dataOffset
            var runningCRC: uLong = zlib.crc32(0, nil, 0)
            while remaining > 0 {
                if shouldCancel() { throw CancellationError() }
                let step = Int(min(remaining, UInt64(chunkSize)))
                let chunk: Data
                do {
                    chunk = try preadExact(fd: fd, offset: offset, count: step)
                } catch {
                    return false
                }
                try addRuntimeBytes(UInt64(chunk.count), to: &cumulativeActualUncompressed)
                chunk.withUnsafeBytes { raw in
                    if let ptr = raw.bindMemory(to: Bytef.self).baseAddress {
                        runningCRC = zlib.crc32(runningCRC, ptr, uInt(chunk.count))
                    }
                }
                guard writeAll(fd: outFD, data: chunk) else { return false }
                offset += UInt64(chunk.count)
                remaining -= UInt64(chunk.count)
            }
            guard fsync(outFD) == 0 else { return false }
            Darwin.close(outFD)
            outOpen = false
            return UInt32(truncatingIfNeeded: runningCRC) == entry.crc32
        } else {
            guard entry.compressedSize > 0 else {
                return false
            }
            let ok = try streamDeflate(
                fd: fd,
                entry: entry,
                destinationFD: outFD,
                stagedURLToUnlinkOnOverflow: stagedURL,
                closeDestination: {
                    if outOpen {
                        Darwin.close(outFD)
                        outOpen = false
                    }
                },
                cumulativeActualUncompressed: &cumulativeActualUncompressed,
                shouldCancel: shouldCancel
            )
            if ok && outOpen {
                guard fsync(outFD) == 0 else { return false }
                Darwin.close(outFD)
                outOpen = false
            }
            return ok
        }
    }

    private static func streamDeflate(
        fd: Int32,
        entry: ArchiveEntry,
        destinationFD: Int32?,
        stagedURLToUnlinkOnOverflow: URL? = nil,
        closeDestination: () -> Void = {},
        cumulativeActualUncompressed: inout UInt64,
        shouldCancel: () -> Bool
    ) throws -> Bool {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return false
        }
        defer { inflateEnd(&stream) }

        var remainingIn = entry.compressedSize
        var offset = entry.dataOffset
        var actualUncompressed: UInt64 = 0
        var actualConsumedInput: UInt64 = 0
        var runningCRC: uLong = zlib.crc32(0, nil, 0)
        var writingToDisk = destinationFD != nil
        var corruptEntry = false
        var reachedStreamEnd = false
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        outer: while true {
            if shouldCancel() { throw CancellationError() }
            let inputChunk: Data
            if remainingIn > 0 {
                let toRead = Int(min(remainingIn, UInt64(chunkSize)))
                do {
                    inputChunk = try preadExact(fd: fd, offset: offset, count: toRead)
                } catch {
                    corruptEntry = true
                    break
                }
                offset += UInt64(inputChunk.count)
                remainingIn -= UInt64(inputChunk.count)
            } else {
                inputChunk = Data()
            }

            let retStatus: Int32 = try inputChunk.withUnsafeBytes { rawIn in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: rawIn.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(inputChunk.count)

                while true {
                    if shouldCancel() { throw CancellationError() }
                    let beforeIn = stream.avail_in
                    let flush = (remainingIn == 0 && stream.avail_in == 0) ? Z_FINISH : Z_NO_FLUSH
                    var status: Int32 = Z_OK
                    var produced = 0

                    outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = uInt(outBuf.count)
                        status = inflate(&stream, flush)
                        produced = outBuf.count - Int(stream.avail_out)
                    }

                    let consumedNow = Int(beforeIn - stream.avail_in)
                    actualConsumedInput += UInt64(consumedNow)

                    if produced > 0 {
                        actualUncompressed += UInt64(produced)
                        try addRuntimeBytes(UInt64(produced), to: &cumulativeActualUncompressed)
                        if exceedsCompressionRatio(uncompressed: actualUncompressed, compressed: entry.compressedSize) {
                            throw ZipArchiveFailure.tooLarge
                        }
                        if actualConsumedInput > 0 && actualUncompressed > 6_400_000 &&
                            exceedsCompressionRatio(uncompressed: actualUncompressed, compressed: actualConsumedInput) {
                            throw ZipArchiveFailure.tooLarge
                        }
                        if writingToDisk {
                            if actualUncompressed > entry.uncompressedSize || actualUncompressed > maxSingleEntryBytes {
                                corruptEntry = true
                                writingToDisk = false
                                closeDestination()
                                if let stagedURLToUnlinkOnOverflow {
                                    try? FileManager.default.removeItem(at: stagedURLToUnlinkOnOverflow)
                                }
                            } else if let outFD = destinationFD {
                                outputBuffer.withUnsafeBufferPointer { outBuf in
                                    runningCRC = zlib.crc32(runningCRC, outBuf.baseAddress, uInt(produced))
                                }
                                let wrote = outputBuffer.withUnsafeBytes { rawOut in
                                    writeBytes(fd: outFD, ptr: rawOut.baseAddress!, count: produced)
                                }
                                if !wrote {
                                    corruptEntry = true
                                    writingToDisk = false
                                    closeDestination()
                                }
                            }
                        }
                    }

                    if status == Z_STREAM_END {
                        return Z_STREAM_END
                    }
                    if status != Z_OK && status != Z_BUF_ERROR {
                        return status
                    }
                    if stream.avail_in == 0 && produced < outputBuffer.count {
                        return Z_OK
                    }
                }
            }

            if retStatus == Z_STREAM_END {
                reachedStreamEnd = true
                break outer
            }
            if retStatus != Z_OK {
                corruptEntry = true
                break outer
            }
            if remainingIn == 0 {
                corruptEntry = true
                break outer
            }
        }

        if exceedsCompressionRatio(uncompressed: actualUncompressed, compressed: actualConsumedInput) {
            throw ZipArchiveFailure.tooLarge
        }
        if !reachedStreamEnd || actualConsumedInput != entry.compressedSize {
            corruptEntry = true
        }
        if corruptEntry || actualUncompressed != entry.uncompressedSize {
            return false
        }
        if destinationFD != nil && UInt32(truncatingIfNeeded: runningCRC) != entry.crc32 {
            return false
        }
        return true
    }

    // MARK: - Low-level File Helpers

    private struct BoundedFileReader {
        let fd: Int32
        var cursor: UInt64
        let endOffset: UInt64
        private var buffer = Data()
        private var bufferPos = 0

        init(fd: Int32, startOffset: UInt64, endOffset: UInt64) {
            self.fd = fd
            self.cursor = startOffset
            self.endOffset = endOffset
        }

        var remaining: UInt64 {
            UInt64(buffer.count - bufferPos) + (endOffset - cursor)
        }

        var isAtEnd: Bool { remaining == 0 }

        mutating func readExact(_ count: Int) throws -> Data {
            guard UInt64(count) <= remaining else { throw ZipArchiveFailure.damaged }
            if buffer.count - bufferPos >= count {
                let slice = Data(buffer[bufferPos..<(bufferPos + count)])
                bufferPos += count
                return slice
            }
            var out = Data()
            out.reserveCapacity(count)
            if bufferPos < buffer.count {
                out.append(buffer[bufferPos..<buffer.count])
                bufferPos = buffer.count
            }
            while out.count < count {
                let needed = count - out.count
                if needed >= ZipArchiveImport.chunkSize {
                    let direct = try preadExact(fd: fd, offset: cursor, count: needed)
                    cursor += UInt64(direct.count)
                    out.append(direct)
                } else {
                    let refillCount = Int(min(UInt64(ZipArchiveImport.chunkSize), endOffset - cursor))
                    guard refillCount > 0 else { throw ZipArchiveFailure.damaged }
                    buffer = try preadExact(fd: fd, offset: cursor, count: refillCount)
                    cursor += UInt64(refillCount)
                    bufferPos = 0
                    let take = min(needed, buffer.count)
                    out.append(buffer[0..<take])
                    bufferPos = take
                }
            }
            return out
        }

        mutating func skipExact(_ count: Int) throws {
            guard UInt64(count) <= remaining else { throw ZipArchiveFailure.damaged }
            let buffered = buffer.count - bufferPos
            if count <= buffered {
                bufferPos += count
            } else {
                let advance = UInt64(count - buffered)
                bufferPos = buffer.count
                cursor += advance
            }
        }
    }

    private static func preadExact(fd: Int32, offset: UInt64, count: Int) throws -> Data {
        if count == 0 { return Data() }
        guard offset <= UInt64(Int64.max), UInt64(count) <= UInt64(Int64.max) - offset else {
            throw ZipArchiveFailure.damaged
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var readTotal = 0
            while readTotal < count {
                let n = Darwin.pread(fd, raw.baseAddress!.advanced(by: readTotal), count - readTotal, off_t(offset) + off_t(readTotal))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ZipArchiveFailure.damaged
                }
                if n == 0 {
                    throw ZipArchiveFailure.damaged
                }
                readTotal += n
            }
        }
        return data
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return true }
            return writeBytes(fd: fd, ptr: ptr, count: raw.count)
        }
    }

    private static func writeBytes(fd: Int32, ptr: UnsafeRawPointer, count: Int) -> Bool {
        var written = 0
        while written < count {
            let n = Darwin.write(fd, ptr.advanced(by: written), count - written)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            written += n
        }
        return true
    }
}

/// Multi-file and ZIP batch importer shared by NSOpenPanel, Finder open, and Drag-and-Drop.
public enum LibraryBatchImport {
    public static func importURLs(
        _ urls: [URL],
        into root: URL,
        additionalRoots: [URL] = [],
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        summary: inout LibraryImportSummary,
        onPartialSummary: (LibraryImportSummary) -> Void = { _ in },
        onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
        shouldCancel: () -> Bool = { false }
    ) throws -> LibraryImportSummary {
        let session = LibraryImport.BatchSession(root: root, additionalRoots: additionalRoots)
        if urls.count == 1, urls[0].pathExtension.lowercased() == "zip" {
            return try ZipArchiveImport.importArchive(
                urls[0],
                into: root,
                additionalRoots: additionalRoots,
                temporaryRoot: temporaryRoot,
                session: session,
                summary: &summary,
                onPartialSummary: onPartialSummary,
                onProgress: onProgress,
                shouldCancel: shouldCancel
            )
        }

        var totalItems = urls.count
        var completedItems = 0
        var singleZipFailure: ZipArchiveFailure?
        var zipCount = 0

        for url in urls {
            if shouldCancel() { throw CancellationError() }
            let ext = url.pathExtension.lowercased()
            if ext == "zip" {
                zipCount += 1
                do {
                    let entryCount = try ZipArchiveImport.supportedEntryCount(in: url, shouldCancel: shouldCancel)
                    if entryCount > 1 {
                        totalItems += (entryCount - 1)
                    }
                    let baseDone = completedItems
                    _ = try ZipArchiveImport.importArchive(
                        url,
                        into: root,
                        additionalRoots: additionalRoots,
                        temporaryRoot: temporaryRoot,
                        session: session,
                        summary: &summary,
                        onPartialSummary: onPartialSummary,
                        onProgress: { archiveDone, _ in
                            onProgress(min(baseDone + archiveDone, totalItems), totalItems)
                        },
                        shouldCancel: shouldCancel
                    )
                    completedItems += max(1, entryCount)
                } catch let cancel as CancellationError {
                    throw cancel
                } catch let failure as ZipArchiveFailure {
                    completedItems += 1
                    onProgress(min(completedItems, totalItems), totalItems)
                    singleZipFailure = failure
                    summary.failed += 1
                    onPartialSummary(summary)
                } catch {
                    completedItems += 1
                    onProgress(min(completedItems, totalItems), totalItems)
                    summary.failed += 1
                    onPartialSummary(summary)
                }
            } else if LibraryImport.supportedAudioExtensions.contains(ext) {
                let currentIndex = min(completedItems + 1, totalItems)
                onProgress(currentIndex, totalItems)
                do {
                    let outcome = try LibraryImport.copyWithOutcome(
                        url,
                        into: root,
                        additionalRoots: additionalRoots,
                        session: session,
                        shouldCancel: shouldCancel
                    )
                    switch outcome {
                    case .imported(let meeting):
                        summary.imported += 1
                        summary.lastSelected = meeting
                    case .duplicate(let meeting):
                        summary.duplicates += 1
                        if summary.lastSelected == nil { summary.lastSelected = meeting }
                    }
                    onPartialSummary(summary)
                } catch let cancel as CancellationError {
                    throw cancel
                } catch {
                    summary.failed += 1
                    onPartialSummary(summary)
                }
                completedItems += 1
            } else {
                let currentIndex = min(completedItems + 1, totalItems)
                onProgress(currentIndex, totalItems)
                summary.unsupported += 1
                onPartialSummary(summary)
                completedItems += 1
            }
        }

        if zipCount == urls.count, let failure = singleZipFailure,
           summary.imported == 0, summary.duplicates == 0, summary.unsupported == 0, summary.failed == 1 {
            throw failure
        }
        return summary
    }
}

private extension Data {
    func u16LE(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1]) << 8
        return b0 | b1
    }

    func u32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1]) << 8
        let b2 = UInt32(self[startIndex + offset + 2]) << 16
        let b3 = UInt32(self[startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    func u64LE(at offset: Int) -> UInt64 {
        let low = UInt64(u32LE(at: offset))
        let high = UInt64(u32LE(at: offset + 4)) << 32
        return low | high
    }
}
