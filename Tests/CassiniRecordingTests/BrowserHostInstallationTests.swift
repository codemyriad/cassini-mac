// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniRecording

@Suite struct BrowserHostInstallationTests {
    @Test func registersOnlyExistingBrowsersAndRetainsRecordingsOnUninstall() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        let executable = home.appendingPathComponent("App With Spaces.app/Contents/MacOS/cassini-browser-host")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let installer = BrowserHostInstallation(home: home, executable: executable)
        #expect(throws: (any Error).self) { _ = try installer.install(extensionID: "../../not-an-extension") }
        let paths = try installer.install(extensionID: String(repeating: "a", count: 32))
        #expect(paths.count == 1)
        let data = try Data(contentsOf: paths[0])
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["name"] as? String == "io.codemyriad.cassini")
        #expect(manifest["path"] as? String == executable.resolvingSymlinksInPath().path)
        #expect(manifest["allowed_origins"] as? [String] == ["chrome-extension://" + String(repeating: "a", count: 32) + "/"])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Microsoft Edge").path))
        let recording = home.appendingPathComponent("Music/Cassini/keep.wav")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: recording)
        #expect(try installer.uninstall() == paths)
        #expect(!FileManager.default.fileExists(atPath: paths[0].path))
        #expect(try Data(contentsOf: recording) == Data([1, 2, 3]))
        #expect(try installer.uninstall().isEmpty)
    }
}
