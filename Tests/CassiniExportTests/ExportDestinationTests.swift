// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniExport

struct ExportDestinationTests {
    @Test(arguments:[true,false]) func selectedFilesNeverFollowALiveOrDanglingSymlink(dangling: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false)
        let artifact = ExportArtifact(directory:stage,filename:"data.md")
        try Data("Export".utf8).write(to:artifact.url)
        let victim = root.appendingPathComponent("keep.md"), link = root.appendingPathComponent("selected.md")
        if !dangling { try Data("Keep".utf8).write(to:victim) }
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:victim)
        #expect(throws:POSIXError(.ELOOP)) { try ExportDestination.selectedFile(artifact,url:link) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath:link.path) == victim.path)
        if !dangling { #expect(try Data(contentsOf:victim) == Data("Keep".utf8)) }
        else { #expect(!FileManager.default.fileExists(atPath:victim.path)) }
    }
    @Test func collisionDoesNotOverwriteAndCancellationLeavesNoPartialFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let staging = root.appendingPathComponent("staging"), output = root.appendingPathComponent("output")
        for folder in [staging,output] { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false) }
        let artifact = ExportArtifact(directory:staging,filename:"data.md")
        let payload = Data(repeating:65,count:2 * 1024 * 1024)
        try payload.write(to:artifact.url)
        let old = output.appendingPathComponent("Meeting.md")
        try Data("Keep this".utf8).write(to:old)
        let saved = try ExportDestination.folder(artifact,directory:output,title:"Meeting",extension:"md")
        #expect(saved.lastPathComponent == "Meeting 2.md")
        #expect(try Data(contentsOf:old) == Data("Keep this".utf8))
        #expect(try Data(contentsOf:saved) == payload)
        var checks = 0
        #expect(throws:CancellationError.self) {
            try ExportDestination.folder(artifact,directory:output,title:"Cancelled",extension:"md",shouldCancel:{ checks += 1; return checks > 1 })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath:output.path).sorted() == ["Meeting 2.md","Meeting.md"])
        // The Save panel path supports both a new file and the user's confirmed
        // replacement, with the old file kept intact until the new one is ready.
        let selected = output.appendingPathComponent("Chosen.md")
        try ExportDestination.selectedFile(artifact,url:selected)
        try Data("New version".utf8).write(to:artifact.url)
        #expect(throws:CancellationError.self) { try ExportDestination.selectedFile(artifact,url:selected,shouldCancel:{ true }) }
        #expect(try Data(contentsOf:selected) == payload)
        try ExportDestination.selectedFile(artifact,url:selected)
        #expect(try Data(contentsOf:selected) == Data("New version".utf8))
    }
}
