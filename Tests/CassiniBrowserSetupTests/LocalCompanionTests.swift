// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import Testing
@_spi(Testing) @testable import CassiniBrowserSetup

private final class CompanionFiles {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cassini-companion-"+UUID().uuidString)
    var home: URL { root.appendingPathComponent("home") }
    var source: URL { root.appendingPathComponent("source") }
    var install: LocalCompanionInstallation { .init(home:home,source:source) }
    var manifest: URL { source.appendingPathComponent("manifest.json") }
    init() throws {
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let url = try #require(Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Fixtures"))
        try Data(contentsOf:url).write(to:manifest)
        try Data("reviewed bytes".utf8).write(to:source.appendingPathComponent("background.js"))
        for url in [manifest,source.appendingPathComponent("background.js")] {
            try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:url.path)
        }
    }
    deinit { try? FileManager.default.removeItem(at:root) }
    func edit(_ change: (inout [String:Any]) -> Void) throws {
        var value = try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any]
        change(&value); try JSONSerialization.data(withJSONObject:value).write(to:manifest)
    }
}
@Suite struct LocalCompanionTests {
    @Test func freshInstallHasThePinnedIdentityAndStableEqualVersionDoesNotRewrite() throws {
        let f = try CompanionFiles(), first = try f.install.install()
        #expect(first.updated && first.version == "0.2.2")
        #expect(f.install.destination.path.hasSuffix("/Library/Application Support/Cassini/BrowserCompanion/extension"))
        let file = f.install.destination.appendingPathComponent("background.js")
        let before = try FileManager.default.attributesOfItem(atPath:file.path)
        #expect(try Data(contentsOf:file) == Data("reviewed bytes".utf8))
        let again = try f.install.install(), after = try FileManager.default.attributesOfItem(atPath:file.path)
        #expect(!again.updated && again.version == first.version)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }
    @Test(arguments:["0.2.2.1","0.10.0","1"])
    func onlyANewerBundledVersionReplacesTheTreeAndNeverDowngrades(_ version: String) throws {
        let f = try CompanionFiles(); _ = try f.install.install()
        try f.edit { $0["version"] = version }
        try Data("new reviewed bytes".utf8).write(to:f.source.appendingPathComponent("background.js"))
        #expect(try f.install.install().updated)
        let file = f.install.destination.appendingPathComponent("background.js")
        #expect(try Data(contentsOf:file) == Data("new reviewed bytes".utf8))
        try f.edit { $0["version"] = "0.2.2" }
        #expect(try !f.install.install().updated)
        #expect(try Data(contentsOf:file) == Data("new reviewed bytes".utf8))
    }
    @Test func aFailedUpdateKeepsTheInstalledTreeAndCleansItsStagingFolder() throws {
        let f = try CompanionFiles(); _ = try f.install.install()
        let file = f.install.destination.appendingPathComponent("manifest.json"), before = try Data(contentsOf:file)
        try f.edit { $0["version"] = "0.2.3" }
        #expect(throws:POSIXError.self) { try f.install.install(beforePublish:{ throw POSIXError(.ENOSPC) }) }
        #expect(try Data(contentsOf:file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath:f.install.destination.deletingLastPathComponent().path).sorted() == [".browser-companion.lock","extension"])
        #expect(try f.install.install().updated)
    }
    @Test(arguments:["0","0.0.0.0","01.2","0.2.","0.2.3.4.5","0.65536","0.2.x"])
    func malformedChromeVersionsCannotCreateOrReplaceAnInstallation(_ version: String) throws {
        let f = try CompanionFiles(); try f.edit { $0["version"] = version }
        #expect(throws:(any Error).self) { try f.install.install() }
        #expect(!FileManager.default.fileExists(atPath:f.install.destination.path))
    }
    @Test func wrongPublicKeyOrDestinationSymlinkIsRejected() throws {
        let f = try CompanionFiles()
        try f.edit { $0["key"] = Data("wrong key".utf8).base64EncodedString() }
        #expect(throws:(any Error).self) { try f.install.install() }
        let clean = try CompanionFiles()
        try FileManager.default.createDirectory(at:clean.install.destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:clean.install.destination,withDestinationURL:clean.source)
        #expect(throws:(any Error).self) { try clean.install.install() }
        #expect(try Data(contentsOf:clean.source.appendingPathComponent("background.js")) == Data("reviewed bytes".utf8))
    }
    @Test(arguments:[false,true]) func sourceLinksCannotEscapeTheBundledTree(hard: Bool) throws {
        let f = try CompanionFiles(), privateFile = f.root.appendingPathComponent("outside")
        try Data("never copied".utf8).write(to:privateFile)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:privateFile.path)
        if hard { try FileManager.default.linkItem(at:privateFile,to:f.source.appendingPathComponent("linked")) }
        else { try FileManager.default.createSymbolicLink(at:f.source.appendingPathComponent("linked"),withDestinationURL:privateFile) }
        #expect(throws:(any Error).self) { try f.install.install() }
        #expect(!FileManager.default.fileExists(atPath:f.install.destination.path))
    }
    @Test func simultaneousPreparationIsRetryableAndDoesNotTouchTheCurrentFolder() throws {
        let f = try CompanionFiles(); _ = try f.install.install()
        let fd = open(f.install.destination.deletingLastPathComponent().appendingPathComponent(".browser-companion.lock").path,O_RDWR | O_NOFOLLOW)
        try #require(fd >= 0); defer { close(fd) }
        try #require(flock(fd,LOCK_EX | LOCK_NB) == 0); defer { flock(fd,LOCK_UN) }
        #expect(throws:BrowserSetupError.self) { try f.install.install() }
        #expect(BrowserSetupFailure(BrowserSetupError.unavailable).retryable)
    }
}
