// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniTranscription

/// Private hard links keep an accepted job's exact files available after Remove.
/// The worker still verifies every D16 source hash before loading them. Kernel
/// scratch leases protect live jobs and allow cleanup after a killed parent.
public final class ParakeetModelLease: @unchecked Sendable {
    private let scratch: SpeechScratch
    public var directory: URL { scratch.directory }
    public init(model: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        scratch = try SpeechScratch(root:temporaryRoot)
        for (name,pin) in ParakeetPin.files {
            let input = model.appendingPathComponent(name), output = directory.appendingPathComponent(name)
            var before = stat(), after = stat()
            guard lstat(input.path,&before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == getuid(), before.st_size >= 0, UInt64(before.st_size) == pin.bytes else { throw ParakeetFailure.invalidModel }
            guard link(input.path,output.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            guard lstat(output.path,&after) == 0,
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino,
                  after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw ParakeetFailure.invalidModel }
        }
    }
}
