// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniKit
import CassiniLibrary

/// A selected-ID snapshot becomes one atomic stored ZIP. Failure never silently drops a selected note.
public enum MeetingArchiveExporter {
    public static func make(_ meetings: [LibraryMeeting], assets: OpusAssets?,
                            temporaryRoot: URL = FileManager.default.temporaryDirectory,
                            limits: ZIPLimits = .init(), shouldCancel: () -> Bool = { false },
                            progress: (TransferProgress) -> Void = { _ in }) throws -> ExportArtifact {
        guard !meetings.isEmpty else { throw ZIPFailure.empty }
        guard meetings.count <= limits.entries else { throw ZIPFailure.tooLarge }
        guard Set(meetings.map(\.libraryKey)).count == meetings.count else { throw MeetingExportError.invalidSource }
        func check() throws { if shouldCancel() { throw CancellationError() } }
        try check()
        let folder = temporaryRoot.appendingPathComponent("CassiniArchive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let artifact = ExportArtifact(directory:folder,filename:"meetings.zip")
        let writer = try StoredZIPWriter(url:artifact.url,limits:limits)
        var used=Set<String>()
        for (index,snapshot) in meetings.enumerated() {
            try check(); progress(.init(done:index,total:meetings.count))
            let current = LibraryScanner.isMeetingFolder(snapshot.folder)
                ? LibraryScanner(root:snapshot.folder.deletingLastPathComponent()).meeting(at:snapshot.folder) : snapshot
            guard let meeting=current, meeting.state.lifecycle == .saved, !meeting.audioFiles.isEmpty else { throw MeetingExportError.invalidSource }
            var prepared: ExportArtifact?
            let raw = folder.appendingPathComponent(UUID().uuidString + ".opus")
            defer { try? FileManager.default.removeItem(at:raw); withExtendedLifetime(prepared) {} }
            var source: URL?
            if meeting.state.origin == .received {
                guard meeting.audioFiles.count == 1, let original=meeting.audioFiles.first else { throw MeetingExportError.invalidSource }
                try TransferFile.copy(original,to:raw,limit:UInt64(UInt32.max),check:check)
                let file = try CassiniReader.read(Data(contentsOf:raw,options:.mappedIfSafe))
                // An audio-only import keeps its original bytes/container. Opaque documents
                // also keep every unknown payload instead of being rebuilt from partial metadata.
                let opaque = [.invalidCassiniMetadata,.unknownCassiniFormat,.staleAudio,.unverified].contains(file.state)
                if opaque {
                    guard meeting.notes.isEmpty, meeting.writtenTranscriptItems.isEmpty else { throw MeetingExportError.invalidSource }
                    source=raw
                } else if file.state == .plainAudio && meeting.notes.isEmpty && meeting.writtenTranscriptItems.isEmpty {
                    source=raw
                }
            }
            if source == nil {
                prepared = try MeetingFileExporter.cassini(meeting,assets:assets,temporaryRoot:folder,shouldCancel:shouldCancel)
                source=prepared?.url
            }
            let title=meeting.title ?? LibraryLocalization.shared.text("library.untitled")
            var collision=1, name=filename(title,collision:1)
            while !used.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                collision += 1; name=filename(title,collision:collision)
            }
            try writer.add(file:source!,name:name,check:check)
        }
        try writer.finish(check:check); try check()
        progress(.init(done:meetings.count,total:meetings.count))
        return artifact
    }
    private static func filename(_ title: String, collision: Int) -> String {
        var name=MeetingMarkdown.filename(title:title.replacingOccurrences(of:":",with:"-"),extension:"opus",collision:collision)
        let suffix=(collision > 1 ? " \(collision)" : "") + ".opus"
        var stem=String(name.dropLast(suffix.count))
        while name.utf8.count > 255 { stem.removeLast(); name=stem+suffix }
        return name
    }
}
