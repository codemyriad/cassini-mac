// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit

public struct TransferProgress: Sendable {
    public let done: Int, total: Int
    public init(done: Int,total: Int) { self.done=done; self.total=total }
}
public struct BulkImportReport: Sendable {
    public var imported=0, duplicates=0, unsupported=0, failed=0
    public var cancelled=false
    public var archives: [ZIPFailure] = []
    public var lastMeeting: LibraryMeeting?
    public init() {}
}

/// Synchronous worker API: the app retains security scopes and runs this off its main actor.
/// Entire directories/local security headers are checked before the first member is imported.
public enum LibraryBulkImport {
    public static func supports(_ name: String) -> Bool { ["opus","ogg"].contains((name as NSString).pathExtension.lowercased()) }
    public static func run(_ urls: [URL], into root: URL, additionalRoots: [URL] = [],
                           temporaryRoot: URL = FileManager.default.temporaryDirectory,
                           limits: ZIPLimits = .init(), memberLimit: UInt64 = UInt64(UInt32.max),
                           shouldCancel: () -> Bool = { false }, progress: (TransferProgress) -> Void = { _ in }) -> BulkImportReport {
        var report=BulkImportReport(), done=0, total=urls.count
        func check() throws { if shouldCancel() { throw CancellationError() } }
        func importFile(_ url: URL, name: String? = nil) throws {
            let result = try LibraryImport.copyResult(url,into:root,additionalRoots:additionalRoots,displayName:name,shouldCancel:shouldCancel)
            if result.duplicate { report.duplicates += 1 } else { report.imported += 1 }
            report.lastMeeting = result.meeting
        }
        for url in urls {
            do {
                try check()
                if url.pathExtension.lowercased() != "zip" {
                    progress(.init(done:done,total:total))
                    defer { done += 1 }
                    guard supports(url.lastPathComponent) else { report.unsupported += 1; continue }
                    try importFile(url); continue
                }
                let scratch = temporaryRoot.appendingPathComponent("CassiniImport-" + UUID().uuidString)
                try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                defer { try? FileManager.default.removeItem(at:scratch) }
                let stagedArchive = scratch.appendingPathComponent("archive.zip")
                // Bound the container too: maximum expanded bytes plus bounded ZIP directory overhead.
                let (containerLimit,overflow) = limits.expandedBytes.addingReportingOverflow(512 * 1024 * 1024)
                guard !overflow else { throw ZIPFailure.tooLarge }
                try TransferFile.copy(url,to:stagedArchive,limit:containerLimit,check:check)
                let archive = try ZIPArchive(url:stagedArchive,limits:limits,check:check)
                total += max(1,archive.entries.count) - 1
                guard archive.entries.contains(where:{ $0.isFile && supports($0.name) }) else {
                    report.unsupported += archive.entries.count; done += max(1,archive.entries.count)
                    throw ZIPFailure.empty
                }
                var observed: UInt64 = 0
                for entry in archive.entries {
                    try check(); progress(.init(done:done,total:total)); defer { done += 1 }
                    let supported = entry.isFile && supports(entry.name)
                    let oversized = entry.expandedBytes > min(memberLimit,UInt64(UInt32.max))
                    let staged = scratch.appendingPathComponent(UUID().uuidString + ".opus")
                    defer { try? FileManager.default.removeItem(at:staged) }
                    var output: FileHandle?
                    defer { try? output?.close() }
                    do {
                        if supported && !oversized {
                            guard FileManager.default.createFile(atPath:staged.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw ZIPFailure.entry }
                            output = try FileHandle(forWritingTo:staged)
                        }
                        // Read/discard unsupported members too, so forged runtime sizes cannot bypass limits.
                        try archive.read(entry,remainingBytes:limits.expandedBytes - observed,check:check,observed:{ count in
                            guard UInt64(count) <= limits.expandedBytes - observed else { throw ZIPFailure.tooLarge }
                            observed += UInt64(count)
                        }) { data in try output?.write(contentsOf:data) }
                        try output?.synchronize(); try output?.close(); output=nil
                        if !supported { report.unsupported += 1 }
                        else if oversized { report.failed += 1 }
                        else { try importFile(staged,name:entry.name) }
                    } catch is CancellationError { throw CancellationError() }
                    catch ZIPFailure.tooLarge { throw ZIPFailure.tooLarge }
                    catch { if supported { report.failed += 1 } else { report.unsupported += 1 } }
                }
            } catch is CancellationError { report.cancelled=true; break }
            catch let failure as ZIPFailure { report.archives.append(failure); report.failed += 1 }
            catch { report.failed += 1 }
        }
        progress(.init(done:done,total:total))
        report.cancelled = report.cancelled || shouldCancel()
        return report
    }
}
