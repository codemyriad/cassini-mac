// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import CassiniKit
import CassiniLibrary
@testable import CassiniExport

struct AlignedExportTests {
    private func imported(_ root: URL) throws -> LibraryMeeting {
        let source = try #require(Bundle.module.url(forResource: "stereo-tone", withExtension: "opus", subdirectory: "Fixtures"))
        return try LibraryImport.copy(source, into: root.appendingPathComponent("Library"))
    }
    @Test func formatPolicyAndOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = try imported(root)
        #expect(!meeting.hasCassiniFile)
        for status in [TranscriptStatus.none, .queued, .running, .failed, .damaged] {
            meeting.state.transcript = status
            #expect(MeetingExportKind.primary(for: meeting) == [.originalAudio])
            #expect(MeetingExportKind.more(for: meeting).isEmpty)
            #expect(throws: MeetingExportError.invalidSource) { try MeetingTextExport.render(meeting, kind: .plainText) }
        }
        let artifact = try MeetingFileExporter.originalAudio(meeting, temporaryRoot: root)
        #expect(try Data(contentsOf: artifact.url) == Data(contentsOf: meeting.audioFiles[0]))
        #expect(MeetingExportKind.originalAudio.suffix(for: meeting) == "opus")
        meeting.hasCassiniFile = true
        #expect(MeetingExportKind.primary(for: meeting) == [.cassini])
        meeting.state.origin = .own
        meeting.hasCassiniFile = false
        #expect(MeetingExportKind.primary(for: meeting) == [.cassini])
        meeting.state.transcript = .done
        #expect(MeetingExportKind.primary(for: meeting) == [.cassini, .markdown])
        #expect(MeetingExportKind.more(for: meeting) == [.plainText, .srt, .vtt])
    }
    @Test func textAndSubtitleConformance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = try imported(root)
        meeting.state.transcript = .done
        meeting.transcriptItems = [
            .init(speaker: "raw-secret-id", startMs: 1500, endMs: 2000, text: "Hello"),
            .init(speaker: "raw-secret-id", startMs: 2000, endMs: 2300, text: "world."),
        ]
        #expect(try MeetingTextExport.render(meeting, kind: .plainText) == "Speaker 1 · 00:00:01\nHello world.\n")
        #expect(try MeetingTextExport.render(meeting, kind: .srt) == "1\n00:00:01,500 --> 00:00:02,300\nSpeaker 1: Hello world.\n")
        #expect(try MeetingTextExport.render(meeting, kind: .vtt) == "WEBVTT\n\n00:00:01.500 --> 00:00:02.300\n<v Speaker 1>Hello world.</v>\n")
        let artifact = try MeetingFileExporter.text(meeting, kind: .vtt, temporaryRoot: root)
        #expect(try String(contentsOf: artifact.url, encoding: .utf8) == MeetingTextExport.render(meeting, kind: .vtt))
        meeting.transcriptItems.append(.init(speaker: "raw-secret-id", startMs: 9000, endMs: 10000, text: "<safe> & sound"))
        let srt = try MeetingTextExport.render(meeting, kind: .srt)
        #expect(srt.contains("2\n00:00:09,000 --> 00:00:10,000\n"))
        #expect(srt.contains("&lt;safe&gt; &amp; sound"))
        meeting.transcriptItems = [
            .init(speaker: "later", startMs: 4000, endMs: 4100, text: "Later"),
            .init(speaker: "earlier", startMs: 1000, endMs: 1000, text: "."),
        ]
        let vtt = try MeetingTextExport.render(meeting, kind: .vtt)
        #expect(vtt.contains("00:00:01.000 --> 00:00:01.001"))
        #expect(try #require(vtt.range(of: ".</v>" )).lowerBound < #require(vtt.range(of: "Later")).lowerBound)
    }
}
