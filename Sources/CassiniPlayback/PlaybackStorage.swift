// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Owns only temporary playback copies, never the recorded source files.
final class PlaybackStorage {
    private(set) var directory: URL?
    deinit { if let directory { try? FileManager.default.removeItem(at: directory) } }

    /// Canonical recorder WAVs use physical complete frames, matching R5. Other
    /// file layouts are left to AVFoundation. Empty canonical sources are skipped.
    func prepare(_ url: URL) throws -> (url: URL, empty: Bool) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SessionComposition.Failure.unreadableAudio }
        var bytes = [UInt8](repeating: 0, count: 44)
        guard pread(fd, &bytes, bytes.count, 0) == 44 else { return (url, false) }
        var header = Data(bytes)
        guard header[0..<4] == Data("RIFF".utf8), header[8..<16] == Data("WAVEfmt ".utf8),
              header[36..<40] == Data("data".utf8) else { return (url, false) }
        func u16(_ at: Int) -> Int { header.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt16.self))) } }
        func u32(_ at: Int) -> UInt32 { header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) } }
        let channels = u16(22), rate = u32(24)
        guard u32(16) == 16, u16(20) == 1, u16(34) == 16, (1...2).contains(channels), (8000...192000).contains(rate),
              u16(32) == channels * 2, u32(28) == rate * UInt32(channels * 2), info.st_size >= 44,
              UInt64(info.st_size) <= UInt64(UInt32.max) + 8 else { throw SessionComposition.Failure.unreadableAudio }
        let frameBytes = channels * 2
        let dataSize = (info.st_size - 44) / Int64(frameBytes) * Int64(frameBytes)
        if dataSize == 0 { return (url, true) }
        if u32(40) == UInt32(dataSize), u32(4) == UInt32(dataSize + 36), info.st_size == dataSize + 44 { return (url, false) }
        if directory == nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-playback-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = root
        }
        let destination = directory!.appendingPathComponent(UUID().uuidString + ".wav")
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        func patch(_ offset: Int, _ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        patch(4, UInt32(dataSize + 36)); patch(40, UInt32(dataSize))
        try output.write(contentsOf: header)
        var remaining = dataSize, position: Int64 = 44
        var block = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            try Task.checkCancellation()
            let count = pread(fd, &block, min(block.count, Int(remaining)), off_t(position))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SessionComposition.Failure.unreadableAudio }
            try output.write(contentsOf: Data(block.prefix(count)))
            remaining -= Int64(count); position += Int64(count)
        }
        return (destination, false)
    }
}
