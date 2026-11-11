// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import zlib
import CassiniKit
import CassiniLibrary

/// D96 bulk stored (uncompressed, method 0) ZIP32/ZIP64 exporter.
/// Streams one meeting at a time directly to an atomic replacement file at the destination,
/// copying unedited received files byte-for-byte so re-import detects duplicates.
public enum BulkZipExporter {
    private static let chunkSize = 64 * 1024

    public static func isExportable(_ meeting: LibraryMeeting) -> Bool {
        guard meeting.state.lifecycle == .saved,
              meeting.state.audioAvailable != false,
              !meeting.audioFiles.isEmpty else {
            return false
        }
        return meeting.audioFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func exportableMeetings(from meetings: [LibraryMeeting]) -> [LibraryMeeting] {
        meetings.filter(isExportable)
    }

    @discardableResult
    public static func export(
        _ meetings: [LibraryMeeting],
        to destinationURL: URL,
        assets: OpusAssets?,
        untitledFallback: String = LibraryLocalization.shared.text("library.untitled"),
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        timeZone: TimeZone = .current,
        isLiveFolder: (URL) -> Bool = { _ in false },
        onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
        shouldCancel: () -> Bool = { false }
    ) throws -> Int {
        try exportInternal(
            meetings,
            to: destinationURL,
            assets: assets,
            untitledFallback: untitledFallback,
            temporaryRoot: temporaryRoot,
            timeZone: timeZone,
            isLiveFolder: isLiveFolder,
            onProgress: onProgress,
            shouldCancel: shouldCancel,
            afterEachEntry: nil
        )
    }

    static func exportInternal(
        _ meetings: [LibraryMeeting],
        to destinationURL: URL,
        assets: OpusAssets?,
        untitledFallback: String = LibraryLocalization.shared.text("library.untitled"),
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        timeZone: TimeZone = .current,
        isLiveFolder: (URL) -> Bool = { _ in false },
        onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
        shouldCancel: () -> Bool = { false },
        afterEachEntry: ((_ index: Int) throws -> Void)?
    ) throws -> Int {
        let candidates = exportableMeetings(from: meetings).filter { !isLiveFolder($0.folder) }
        guard !candidates.isEmpty else {
            throw MeetingExportError.invalidSource
        }

        let replacing = try existingRegular(at: destinationURL)
        let manager = FileManager.default
        let replacementDir = try manager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )
        defer { try? manager.removeItem(at: replacementDir) }

        let pendingZip = replacementDir.appendingPathComponent("archive.zip.tmp")
        let zipFD = Darwin.open(pendingZip.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard zipFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var zipOpen = true
        defer {
            if zipOpen { Darwin.close(zipFD) }
        }

        var writer = StoredZipWriter(fd: zipFD, timeZone: timeZone)
        var usedEntryNamesLower = Set<String>()
        var nextCollisionByBase: [String: Int] = [:]
        var scannersByRoot: [URL: LibraryScanner] = [:]
        var writtenEntries = 0

        for (index, snapshot) in candidates.enumerated() {
            if shouldCancel() { throw CancellationError() }
            if isLiveFolder(snapshot.folder) { continue }
            onProgress(index + 1, candidates.count)

            let current: LibraryMeeting
            if LibraryScanner.isMeetingFolder(snapshot.folder) {
                let root = snapshot.folder.deletingLastPathComponent().standardizedFileURL
                let scanner = scannersByRoot[root] ?? {
                    let created = LibraryScanner(root: root)
                    scannersByRoot[root] = created
                    return created
                }()
                guard let refreshed = scanner.meeting(at: snapshot.folder),
                      refreshed.state.lifecycle == .saved,
                      Self.isExportable(refreshed),
                      !isLiveFolder(refreshed.folder) else {
                    continue
                }
                current = refreshed
            } else {
                guard snapshot.state.lifecycle == .saved, Self.isExportable(snapshot) else {
                    continue
                }
                current = snapshot
            }

            let baseTitle = [current.exportTitle, current.title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? untitledFallback
            let entryName = try uniqueEntryName(
                title: baseTitle,
                usedLowercased: &usedEntryNamesLower,
                nextCollisionByBase: &nextCollisionByBase
            )
            let modifiedDate = current.start ?? Date()

            if let rawSourceURL = try directCopySourceURL(for: current) {
                try writer.appendFile(
                    from: rawSourceURL,
                    entryName: entryName,
                    modifiedAt: modifiedDate,
                    shouldCancel: shouldCancel
                )
            } else {
                do {
                    try autoreleasepool {
                        let artifact = try MeetingFileExporter.cassini(
                            current,
                            assets: current.state.origin == .own ? assets : nil,
                            temporaryRoot: temporaryRoot,
                            timeZone: timeZone,
                            shouldCancel: shouldCancel
                        )
                        defer {
                            try? manager.removeItem(at: artifact.url.deletingLastPathComponent())
                        }
                        try writer.appendFile(
                            from: artifact.url,
                            entryName: entryName,
                            modifiedAt: modifiedDate,
                            shouldCancel: shouldCancel
                        )
                    }
                } catch MeetingExportError.newerFormat where current.state.origin == .received && current.audioFiles.count == 1 {
                    try writer.appendFile(
                        from: current.audioFiles[0],
                        entryName: entryName,
                        modifiedAt: modifiedDate,
                        shouldCancel: shouldCancel
                    )
                }
            }

            writtenEntries += 1
            try afterEachEntry?(index)
        }

        guard writtenEntries > 0 else {
            throw MeetingExportError.invalidSource
        }

        if shouldCancel() { throw CancellationError() }
        try writer.finish(shouldCancel: shouldCancel)
        guard fsync(zipFD) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Darwin.close(zipFD)
        zipOpen = false

        if shouldCancel() { throw CancellationError() }
        _ = try existingRegular(at: destinationURL)
        let flags = replacing ? UInt32(0) : UInt32(RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, pendingZip.path, AT_FDCWD, destinationURL.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return writtenEntries
    }

    /// Determines whether `meeting` must have its `original.opus` copied byte-for-byte:
    /// - Any non-OK Cassini source (`.unverified`, `.staleAudio`, `.unknownCassiniFormat`, `.invalidCassiniMetadata`),
    ///   even when locally edited, because rebuilding would strip its original transcripts, manifest, and tags;
    /// - Any `.ok` source carrying a foreign `codemyriad.io` namespace this app cannot advance;
    /// - Any unedited `.ok` Cassini document or unedited `.plainAudio` file, so re-import detects duplicates.
    static func directCopySourceURL(for meeting: LibraryMeeting) throws -> URL? {
        guard meeting.state.origin == .received,
              meeting.state.lifecycle == .saved,
              meeting.audioFiles.count == 1,
              let sourceURL = meeting.audioFiles.first else {
            return nil
        }

        var info = stat()
        guard lstat(sourceURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw MeetingExportError.invalidSource
        }

        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let file = try CassiniReader.read(data)
        guard case .success? = file.audioDigest else {
            throw MeetingExportError.invalidSource
        }

        let trusted = [.ok, .plainAudio].contains(file.state)
        if !trusted {
            return sourceURL
        }

        if let foreign = file.manifest?.raw["x"]?[CodemyriadNamespace.key],
           (try? CodemyriadNamespace.validated(foreign)) == nil {
            return sourceURL
        }

        if !LibraryScanner.isMeetingFolder(meeting.folder) {
            return sourceURL
        }

        let metadataURL = meeting.folder.appendingPathComponent("meeting.json")
        let raw = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONParser.parse($0) }
        let embeddedTitle = [file.manifest?.meeting.title, file.tags?["TITLE"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if raw?["titleSource"]?.string == "user" {
            return nil
        }
        if raw != nil, raw?["title"] == .null, (embeddedTitle != nil || (raw?["revision"]?.int ?? 0) > 0) {
            return nil
        }

        let originalNotes = file.manifest?.raw["x"]?["gocassini.com"]?["notes"]
        let (_, notesChanged) = CodemyriadNamespace.exportNotes(
            local: CodemyriadNamespace.localNotes(raw),
            original: originalNotes
        )
        if notesChanged {
            return nil
        }

        let importedTranscript = LibraryImport.importedTranscript(file)
        if CodemyriadNamespace.transcribedOnMac(raw, importedTranscript: importedTranscript),
           meeting.state.transcript == .done {
            return nil
        }

        let speakerEdited = (raw?["speakers"]?.array ?? []).contains { entry in
            entry["provenance"]?.string == "user" || entry["nameCleared"] == .bool(true)
        }
        if speakerEdited {
            return nil
        }

        if !(raw?["speakerMerges"]?.array ?? []).isEmpty {
            return nil
        }

        if let quoteOverride = raw?["quoteOverride"], quoteOverride != .null {
            return nil
        }

        return sourceURL
    }

    static func uniqueEntryName(
        title: String,
        usedLowercased: inout Set<String>,
        nextCollisionByBase: inout [String: Int]
    ) throws -> String {
        let suffix = "opus"
        let baseCandidate = formattedEntryName(title: title, suffix: suffix, collision: 1)
        let baseKey = baseCandidate.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let startCollision = nextCollisionByBase[baseKey] ?? 1
        guard startCollision <= 100_000 else { throw POSIXError(.EEXIST) }

        for collision in startCollision...100_000 {
            let name = collision == 1
                ? baseCandidate
                : formattedEntryName(title: title, suffix: suffix, collision: collision)
            let key = collision == 1
                ? baseKey
                : name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if usedLowercased.insert(key).inserted {
                nextCollisionByBase[baseKey] = collision + 1
                return name
            }
        }
        throw POSIXError(.EEXIST)
    }

    private static func formattedEntryName(title: String, suffix: String, collision: Int) -> String {
        var name = MeetingMarkdown.filename(title: title, extension: suffix, collision: collision)
        if name.utf8.count > 255 {
            let ending = (collision > 1 ? " \(collision)" : "") + "." + suffix
            var stem = String(name.dropLast(ending.count))
            while (stem + ending).utf8.count > 255 && !stem.isEmpty {
                stem.removeLast()
            }
            name = stem + ending
        }
        return name
    }

    private static func existingRegular(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.ELOOP) }
            return true
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return false
    }

    // MARK: - Stored (Method 0) Streaming ZIP32 / ZIP64 Writer

    private struct WrittenEntryRecord {
        let nameBytes: Data
        let dosTime: UInt16
        let dosDate: UInt16
        let crc32: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
    }

    private struct StoredZipWriter {
        let fd: Int32
        let timeZone: TimeZone
        private var currentOffset: UInt64 = 0
        private var records: [WrittenEntryRecord] = []

        init(fd: Int32, timeZone: TimeZone) {
            self.fd = fd
            self.timeZone = timeZone
        }

        mutating func appendFile(
            from sourceURL: URL,
            entryName: String,
            modifiedAt: Date,
            shouldCancel: () -> Bool
        ) throws {
            let sourceFD = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.close(sourceFD) }

            var beforeStat = stat()
            guard fstat(sourceFD, &beforeStat) == 0,
                  (beforeStat.st_mode & S_IFMT) == S_IFREG,
                  beforeStat.st_size >= 0 else {
                throw MeetingExportError.invalidSource
            }
            let expectedSize = UInt64(beforeStat.st_size)
            let nameBytes = Data(entryName.utf8)
            let (dosTime, dosDate) = Self.dosDateTime(modifiedAt, timeZone: timeZone)

            let localHeaderOffset = currentOffset
            let needsLocalZip64 = expectedSize >= 0xFFFF_FFFF
            let versionNeeded: UInt16 = needsLocalZip64 ? 45 : 20
            let flags: UInt16 = 0x0800 // Bit 11: UTF-8 filename

            var localExtra = Data()
            if needsLocalZip64 {
                localExtra.appendU16LE(0x0001)
                localExtra.appendU16LE(16)
                localExtra.appendU64LE(expectedSize)
                localExtra.appendU64LE(expectedSize)
            }

            var localHeader = Data(capacity: 30 + nameBytes.count + localExtra.count)
            localHeader.appendU32LE(0x0403_4b50)
            localHeader.appendU16LE(versionNeeded)
            localHeader.appendU16LE(flags)
            localHeader.appendU16LE(0) // Method 0: Stored
            localHeader.appendU16LE(dosTime)
            localHeader.appendU16LE(dosDate)
            localHeader.appendU32LE(0) // CRC-32 patched via pwrite at localHeaderOffset + 14
            localHeader.appendU32LE(needsLocalZip64 ? 0xFFFF_FFFF : UInt32(expectedSize))
            localHeader.appendU32LE(needsLocalZip64 ? 0xFFFF_FFFF : UInt32(expectedSize))
            localHeader.appendU16LE(UInt16(nameBytes.count))
            localHeader.appendU16LE(UInt16(localExtra.count))
            localHeader.append(nameBytes)
            localHeader.append(localExtra)

            try writeAll(localHeader)

            var runningCRC: uLong = zlib.crc32(0, nil, 0)
            var copied: UInt64 = 0
            var readBuffer = [UInt8](repeating: 0, count: BulkZipExporter.chunkSize)

            while true {
                if shouldCancel() { throw CancellationError() }
                let readCount: Int = try readBuffer.withUnsafeMutableBytes { raw in
                    while true {
                        let n = Darwin.read(sourceFD, raw.baseAddress!, raw.count)
                        if n < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        return n
                    }
                }
                if readCount == 0 { break }
                copied += UInt64(readCount)
                guard copied <= expectedSize else {
                    throw MeetingExportError.invalidSource
                }
                readBuffer.withUnsafeBufferPointer { buf in
                    runningCRC = zlib.crc32(runningCRC, buf.baseAddress, uInt(readCount))
                }
                try readBuffer.withUnsafeBytes { raw in
                    try writeBytes(ptr: raw.baseAddress!, count: readCount)
                }
            }

            var afterStat = stat()
            guard copied == expectedSize,
                  fstat(sourceFD, &afterStat) == 0,
                  afterStat.st_dev == beforeStat.st_dev,
                  afterStat.st_ino == beforeStat.st_ino,
                  afterStat.st_size == beforeStat.st_size else {
                throw MeetingExportError.invalidSource
            }

            let finalCRC = UInt32(truncatingIfNeeded: runningCRC)
            var crcBytes = Data(capacity: 4)
            crcBytes.appendU32LE(finalCRC)
            try pwriteAll(crcBytes, at: localHeaderOffset + 14)

            records.append(WrittenEntryRecord(
                nameBytes: nameBytes,
                dosTime: dosTime,
                dosDate: dosDate,
                crc32: finalCRC,
                size: expectedSize,
                localHeaderOffset: localHeaderOffset
            ))
        }

        mutating func finish(shouldCancel: () -> Bool) throws {
            let centralDirOffset = currentOffset
            for (i, record) in records.enumerated() {
                if (i & 0xFF) == 0 && shouldCancel() { throw CancellationError() }
                let needsSize64 = record.size >= 0xFFFF_FFFF
                let needsOffset64 = record.localHeaderOffset >= 0xFFFF_FFFF
                let needsZip64 = needsSize64 || needsOffset64

                var cdExtra = Data()
                if needsZip64 {
                    var payload = Data()
                    if needsSize64 {
                        payload.appendU64LE(record.size)
                        payload.appendU64LE(record.size)
                    }
                    if needsOffset64 {
                        payload.appendU64LE(record.localHeaderOffset)
                    }
                    cdExtra.appendU16LE(0x0001)
                    cdExtra.appendU16LE(UInt16(payload.count))
                    cdExtra.append(payload)
                }

                let versionNeeded: UInt16 = needsZip64 ? 45 : 20
                let versionMadeBy: UInt16 = (3 << 8) | versionNeeded // Unix + spec version
                let externalAttrs: UInt32 = UInt32(0o100644) << 16

                var cdHeader = Data(capacity: 46 + record.nameBytes.count + cdExtra.count)
                cdHeader.appendU32LE(0x0201_4b50)
                cdHeader.appendU16LE(versionMadeBy)
                cdHeader.appendU16LE(versionNeeded)
                cdHeader.appendU16LE(0x0800) // UTF-8
                cdHeader.appendU16LE(0) // Method 0: Stored
                cdHeader.appendU16LE(record.dosTime)
                cdHeader.appendU16LE(record.dosDate)
                cdHeader.appendU32LE(record.crc32)
                cdHeader.appendU32LE(needsSize64 ? 0xFFFF_FFFF : UInt32(record.size))
                cdHeader.appendU32LE(needsSize64 ? 0xFFFF_FFFF : UInt32(record.size))
                cdHeader.appendU16LE(UInt16(record.nameBytes.count))
                cdHeader.appendU16LE(UInt16(cdExtra.count))
                cdHeader.appendU16LE(0) // Comment length
                cdHeader.appendU16LE(0) // Disk number start
                cdHeader.appendU16LE(0) // Internal attributes
                cdHeader.appendU32LE(externalAttrs)
                cdHeader.appendU32LE(needsOffset64 ? 0xFFFF_FFFF : UInt32(record.localHeaderOffset))
                cdHeader.append(record.nameBytes)
                cdHeader.append(cdExtra)

                try writeAll(cdHeader)
            }

            let centralDirSize = currentOffset - centralDirOffset
            let entryCount = UInt64(records.count)
            let needsZip64EOCD =
                entryCount >= 0xFFFF ||
                centralDirSize >= 0xFFFF_FFFF ||
                centralDirOffset >= 0xFFFF_FFFF

            if needsZip64EOCD {
                let zip64EOCDOffset = currentOffset
                var z64 = Data(capacity: 56)
                z64.appendU32LE(0x0606_4b50)
                z64.appendU64LE(44) // Remaining size of ZIP64 EOCD
                z64.appendU16LE((3 << 8) | 45)
                z64.appendU16LE(45)
                z64.appendU32LE(0) // Disk number
                z64.appendU32LE(0) // Disk with central directory
                z64.appendU64LE(entryCount)
                z64.appendU64LE(entryCount)
                z64.appendU64LE(centralDirSize)
                z64.appendU64LE(centralDirOffset)
                try writeAll(z64)

                var locator = Data(capacity: 20)
                locator.appendU32LE(0x0706_4b50)
                locator.appendU32LE(0) // Disk with ZIP64 EOCD
                locator.appendU64LE(zip64EOCDOffset)
                locator.appendU32LE(1) // Total disks
                try writeAll(locator)
            }

            var eocd = Data(capacity: 22)
            eocd.appendU32LE(0x0605_4b50)
            eocd.appendU16LE(0)
            eocd.appendU16LE(0)
            let count16: UInt16 = entryCount >= 0xFFFF ? 0xFFFF : UInt16(entryCount)
            eocd.appendU16LE(count16)
            eocd.appendU16LE(count16)
            eocd.appendU32LE(centralDirSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(centralDirSize))
            eocd.appendU32LE(centralDirOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(centralDirOffset))
            eocd.appendU16LE(0)
            try writeAll(eocd)
        }

        private mutating func writeAll(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, !raw.isEmpty else { return }
                try writeBytes(ptr: base, count: raw.count)
            }
        }

        private mutating func writeBytes(ptr: UnsafeRawPointer, count: Int) throws {
            var written = 0
            while written < count {
                let n = Darwin.write(fd, ptr.advanced(by: written), count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard n > 0 else { throw POSIXError(.EIO) }
                written += n
            }
            currentOffset += UInt64(count)
        }

        private func pwriteAll(_ data: Data, at offset: UInt64) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let n = Darwin.pwrite(fd, base.advanced(by: written), raw.count - written, off_t(offset) + off_t(written))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard n > 0 else { throw POSIXError(.EIO) }
                    written += n
                }
            }
        }

        private static func dosDateTime(_ date: Date, timeZone: TimeZone) -> (time: UInt16, date: UInt16) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let year = min(max(comps.year ?? 1980, 1980), 2107)
            let month = min(max(comps.month ?? 1, 1), 12)
            let day = min(max(comps.day ?? 1, 1), 31)
            let hour = min(max(comps.hour ?? 0, 0), 23)
            let minute = min(max(comps.minute ?? 0, 0), 59)
            let second = min(max(comps.second ?? 0, 0), 59) / 2
            let dosTime = UInt16((hour << 11) | (minute << 5) | second)
            let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
            return (dosTime, dosDate)
        }
    }
}

private extension Data {
    mutating func appendU16LE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendU32LE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendU64LE(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
