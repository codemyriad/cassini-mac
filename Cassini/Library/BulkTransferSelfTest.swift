// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniKit
import CassiniLibrary
import Darwin

/// Actual coordinator/scopes/save composition, isolated to the existing private RAM fixture.
@MainActor enum BulkTransferSelfTest {
    static func run() async {
        guard RecordingFixture.enabled, SettingsFixture.id != nil, let root=RecordingFixture.root,
              ProcessInfo.processInfo.environment["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" ||
                ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {exit(78)}
        do {
            NSLog("Bulk transfer phase: setup")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:root)}
            guard let fixture=Bundle.main.url(forResource:"meeting",withExtension:"opus",subdirectory:"Fixtures") else {throw CocoaError(.fileNoSuchFile)}
            let source=root.appendingPathComponent("English meeting.opus")
            _ = try OpusStreamFile.rewrite(Data(contentsOf:fixture),tags:PortableMeetingTags.packet(),to:source)
            let archive=root.appendingPathComponent("Input.zip"),writer=try StoredZIPWriter(url:root.appendingPathComponent("Input.zip"))
            try writer.add(file:source,name:"English meeting.opus")
            try writer.finish()
            let transfer=LibraryBulkTransfer.shared
            NSLog("Bulk transfer phase: multiple import")
            transfer.importFiles([source,archive]);await transfer.wait()
            NSLog("Bulk transfer phase: multiple import handled")
            guard let report=transfer.lastImportReport,report.imported==1,report.duplicates==1,report.failed==0,
                  let first=report.lastMeeting,transfer.message?.contains("Imported 1")==true else {throw CocoaError(.fileReadCorruptFile)}
            let secondSource=root.appendingPathComponent("Second.opus")
            _ = try OpusStreamFile.rewrite(Data(contentsOf:source),tags:PortableMeetingTags.packet(comments:[.init(name:"TITLE",value:"Second meeting")]),to:secondSource)
            NSLog("Bulk transfer phase: second import")
            transfer.importFiles([secondSource]);await transfer.wait()
            let meetings=try LibraryScanner(root:root).scan().meetings
            guard meetings.count==2 else {throw CocoaError(.fileReadCorruptFile)}
            let all=root.appendingPathComponent("All.zip"),selected=root.appendingPathComponent("Selected.zip")
            NSLog("Bulk transfer phase: all export")
            await transfer.exportForTesting(meetings,to:all)
            guard try ZIPArchive(url:all).entries.count==2 else {throw CocoaError(.fileWriteUnknown)}
            NSLog("Bulk transfer phase: selected export")
            await transfer.exportForTesting([first],to:selected)
            let saved=try ZIPArchive(url:selected);var original=Data()
            try saved.read(saved.entries[0],remainingBytes:20_000_000_000) {original.append($0)}
            guard saved.entries.count==1,saved.entries[0].method==0,original == (try Data(contentsOf:source)) else {throw CocoaError(.fileReadCorruptFile)}
            let cancelledSave=root.appendingPathComponent("Cancelled.zip")
            NSLog("Bulk transfer phase: stale choice")
            await transfer.staleExportChoiceForTesting([first],to:cancelledSave)
            guard !transfer.busy,!FileManager.default.fileExists(atPath:cancelledSave.path) else {throw CocoaError(.userCancelled)}
            let fresh=root.appendingPathComponent("Never imported.opus")
            _ = try OpusStreamFile.rewrite(Data(contentsOf:source),tags:PortableMeetingTags.packet(comments:[.init(name:"TITLE",value:"Never imported")]),to:fresh)
            let cancelZip=root.appendingPathComponent("Cancel.zip"),cancelWriter=try StoredZIPWriter(url:root.appendingPathComponent("Cancel.zip"))
            try cancelWriter.add(file:fresh,name:"Never imported.opus");try cancelWriter.finish()
            let beforeIDs=Set(meetings.map(\.id))
            NSLog("Bulk transfer phase: cancellation")
            transfer.importFiles([cancelZip]);transfer.cancel();await transfer.wait()
            guard let cancelled=transfer.lastImportReport,cancelled.cancelled,cancelled.imported==0,cancelled.duplicates==0,!transfer.busy,
                  Set(try LibraryScanner(root:root).scan().meetings.map(\.id))==beforeIDs else {throw CocoaError(.userCancelled)}
            for language in CassiniLanguage.allCases {
                let copy=LibraryLocalization.shared.text("import.summary.imported",["n":"2"],language:language)
                guard !copy.contains("{n}") else {throw CocoaError(.fileReadCorruptFile)}
            }
            let result:[String:Any] = ["multipleImport":true,"zipImport":true,"ordinaryDedup":true,"storedAllExport":true,
                "selectedExport":true,"originalAudioBytes":true,"queuedCancellation":true,"staleSaveChoiceRejected":true,"localizedSummary":true,"audioDevicesOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:.sortedKeys));exit(0)
        } catch { fputs("Bulk transfer proof failed: \(error)\n",stderr);exit(1) }
    }
}
#endif
