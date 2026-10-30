// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
@_spi(Testing) import CassiniBrowserSetup

private func setupRunsOffMainThread() -> Bool { !Thread.isMainThread }

final class InstallationTests: XCTestCase {
    private var root: URL!, contents: URL!, home: URL!
    override func setUpWithError() throws {
        let temporary = try XCTUnwrap(realpath(NSTemporaryDirectory(),nil))
        defer { free(temporary) }
        root = URL(fileURLWithPath:String(cString:temporary),isDirectory:true).appendingPathComponent("CassiniConnectTests-" + UUID().uuidString)
        home = root.appendingPathComponent("home"); contents = root.appendingPathComponent("Cassini.app/Contents")
        try FileManager.default.createDirectory(at:contents.appendingPathComponent("MacOS"),withIntermediateDirectories:true)
        for executable in ["cassini-browser-host","cassini-control-host"] {
            let file = contents.appendingPathComponent("MacOS/" + executable)
            try Data("generated executable fixture".utf8).write(to:file)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    private func leaf(_ browser: String) -> URL { home.appendingPathComponent("Library/Application Support/" + browser + "/NativeMessagingHosts") }
    private func prepare(_ browsers: [String] = BrowserSetupInstallation.browsers) throws {
        for browser in browsers { try FileManager.default.createDirectory(at:leaf(browser).deletingLastPathComponent(),withIntermediateDirectories:true) }
    }
    private var installation: BrowserSetupInstallation { .init(home:home,contents:contents) }
    private func legacy(_ browser: String, name: String = "com.codemyriad.cassini", manifestName: String? = nil, executable: String = "cassini-browser-host") throws -> URL {
        let directory = leaf(browser)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file = directory.appendingPathComponent(name + ".json")
        let data = try JSONSerialization.data(withJSONObject:["name":manifestName ?? name,"path":"/Old Cassini.app/Contents/MacOS/" + executable,"allowed_origins":["chrome-extension://different-origin/"]])
        try data.write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        return file
    }
    func testOwnLegacyManifestsAreRemovedWithoutMatchingOrigins() throws {
        try prepare()
        var old: [URL] = []
        for browser in BrowserSetupInstallation.browsers {
            old.append(try legacy(browser))
            old.append(try legacy(browser,name:"com.codemyriad.cassini.control",executable:"cassini-control-host"))
        }
        XCTAssertEqual(try installation.install(),8)
        for file in old { XCTAssertFalse(FileManager.default.fileExists(atPath:file.path)) }
        XCTAssertEqual(try installation.install(),8)
    }
    func testLegacyOwnershipRequiresFileNameManifestNameAndOwnExecutable() throws {
        try prepare()
        let mismatch = try legacy("Google/Chrome",manifestName:"another.host")
        let executable = try legacy("Chromium",executable:"another-host")
        let name = try legacy("Microsoft Edge",name:"unrelated.host",manifestName:"com.codemyriad.cassini")
        let corrupt = try legacy("BraveSoftware/Brave-Browser")
        try Data("not JSON".utf8).write(to:corrupt)
        let files = try [mismatch,executable,name,corrupt].map { ($0,try Data(contentsOf:$0)) }
        XCTAssertEqual(try installation.install(),8)
        for (file,data) in files { XCTAssertEqual(try Data(contentsOf:file),data) }
    }
    func testLegacyDeletionRollsBackTogetherWithNewManifests() throws {
        try prepare()
        let first = try legacy("Google/Chrome")
        let second = try legacy("Google/Chrome",name:"com.codemyriad.cassini.control",executable:"cassini-control-host")
        let expected = try [first,second].map { ($0,try Data(contentsOf:$0)) }
        XCTAssertThrowsError(try installation.install { index in
            if !FileManager.default.fileExists(atPath:second.path) { throw CocoaError(.fileWriteOutOfSpace) }
        })
        for (file,data) in expected { XCTAssertEqual(try Data(contentsOf:file),data) }
        for browser in BrowserSetupInstallation.browsers {
            XCTAssertFalse(FileManager.default.fileExists(atPath:leaf(browser).appendingPathComponent("io.codemyriad.cassini.json").path))
        }
    }
    func testUnsafeLegacyEntriesAreLeftAlone() throws {
        try prepare()
        let outside = root.appendingPathComponent("keep");try Data("keep".utf8).write(to:outside)
        let symlink = try legacy("Google/Chrome");try FileManager.default.removeItem(at:symlink)
        try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:outside)
        let pipe = try legacy("Chromium");try FileManager.default.removeItem(at:pipe);XCTAssertEqual(mkfifo(pipe.path,0o600),0)
        let linked = try legacy("Microsoft Edge");try FileManager.default.removeItem(at:linked);try FileManager.default.linkItem(at:outside,to:linked)
        let oversized = try legacy("BraveSoftware/Brave-Browser");try Data(repeating:0,count:65537).write(to:oversized)
        XCTAssertEqual(try installation.install(),8)
        XCTAssertEqual(try Data(contentsOf:outside),Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:symlink.path),outside.path)
        var info = stat();XCTAssertEqual(lstat(pipe.path,&info),0);XCTAssertEqual(info.st_mode & S_IFMT,S_IFIFO)
        XCTAssertTrue(FileManager.default.fileExists(atPath:linked.path));XCTAssertEqual(try Data(contentsOf:oversized).count,65537)
    }
    func testRegistersBothHostsWithPinnedOriginAndPrivateModesInAllFourBrowsers() throws {
        try prepare()
        XCTAssertEqual(try installation.install(),8)
        for browser in BrowserSetupInstallation.browsers {
            for (name,executable) in [("io.codemyriad.cassini","cassini-browser-host"),("io.codemyriad.cassini.control","cassini-control-host")] {
                let file = leaf(browser).appendingPathComponent(name + ".json")
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
                XCTAssertEqual(object["allowed_origins"] as? [String],[BrowserSetupInstallation.origin])
                XCTAssertEqual(object["path"] as? String,contents.appendingPathComponent("MacOS/" + executable).path)
                XCTAssertEqual(object["name"] as? String,name); XCTAssertEqual(object["type"] as? String,"stdio")
                XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
            }
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:leaf(browser).path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        }
    }
    @MainActor func testLaunchTriggerInstallsMissingManifestsWithoutConnectAction() async throws {
        try prepare(["Google/Chrome"])
        let home = try XCTUnwrap(self.home), contents = try XCTUnwrap(self.contents)
        let setup = BackgroundBrowserSetup {
            guard setupRunsOffMainThread() else { throw BrowserSetupError.unavailable }
            _ = try BrowserSetupInstallation(home:home,contents:contents).install()
        }
        defer { setup.stop() }
        setup.trigger()
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while setup.state == .settingUp && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(setup.state,.waiting)
        for name in ["io.codemyriad.cassini","io.codemyriad.cassini.control"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath:leaf("Google/Chrome").appendingPathComponent(name + ".json").path))
        }
    }
    func testIdenticalManifestsKeepMtimeAndInodeEvenWithDifferentJSONFormatting() throws {
        try prepare(["Google/Chrome"]); XCTAssertEqual(try installation.install(),2)
        let files = ["io.codemyriad.cassini", "io.codemyriad.cassini.control"].map { leaf("Google/Chrome").appendingPathComponent($0 + ".json") }
        var before: [(Date,UInt64)] = []
        for file in files {
            let object = try JSONSerialization.jsonObject(with:Data(contentsOf:file))
            try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted]).write(to:file)
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:123456)],ofItemAtPath:file.path)
            let info = try FileManager.default.attributesOfItem(atPath:file.path)
            before.append((try XCTUnwrap(info[.modificationDate] as? Date),try XCTUnwrap(info[.systemFileNumber] as? UInt64)))
        }
        XCTAssertEqual(try installation.install { _ in XCTFail("An identical manifest must never be published") },2)
        for (index,file) in files.enumerated() {
            let info = try FileManager.default.attributesOfItem(atPath:file.path)
            XCTAssertEqual(info[.modificationDate] as? Date,before[index].0)
            XCTAssertEqual(info[.systemFileNumber] as? UInt64,before[index].1)
        }
    }
    func testUnwritableConfigIsPermanentWithoutPublishingAnyManifest() throws {
        try prepare(["Google/Chrome"])
        let directory = leaf("Google/Chrome")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o500])
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path) }
        XCTAssertThrowsError(try installation.install()) { error in
            XCTAssertEqual(BrowserSetupFailure(error),.unwritable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),[])
    }
    func testMoveRewritesBothPathsAndWrongOriginIsRepaired() throws {
        try prepare(["Google/Chrome"]); _ = try installation.install()
        let moved = root.appendingPathComponent("Moved Cassini.app/Contents")
        try FileManager.default.createDirectory(at:moved.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.moveItem(at:contents,to:moved)
        XCTAssertEqual(try BrowserSetupInstallation(home:home,contents:moved).install(),2)
        for name in ["io.codemyriad.cassini", "io.codemyriad.cassini.control"] {
            let file = leaf("Google/Chrome").appendingPathComponent(name + ".json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
            XCTAssertTrue(try XCTUnwrap(object["path"] as? String).hasPrefix(moved.path + "/"))
            object["allowed_origins"] = ["chrome-extension://wrong/"]
            try JSONSerialization.data(withJSONObject:object).write(to:file)
        }
        XCTAssertEqual(try BrowserSetupInstallation(home:home,contents:moved).install(),2)
        for name in ["io.codemyriad.cassini", "io.codemyriad.cassini.control"] {
            let file = leaf("Google/Chrome").appendingPathComponent(name + ".json")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
            XCTAssertEqual(object["allowed_origins"] as? [String],[BrowserSetupInstallation.origin])
        }
    }
    func testRepeatConnectRepairsAStalePathAndSkipsBrowsersThatNeverRan() throws {
        try prepare(["Google/Chrome"])
        XCTAssertEqual(try installation.install(),2)
        let file = leaf("Google/Chrome").appendingPathComponent("io.codemyriad.cassini.json")
        try Data("old app location".utf8).write(to:file)
        XCTAssertEqual(try installation.install(),2)
        XCTAssertTrue(try String(contentsOf:file,encoding:.utf8).contains("cassini-browser-host"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:leaf("Chromium").deletingLastPathComponent().path))
    }
    func testFailureRollsBackEveryPreviouslyPublishedManifestAndLeavesNoStagingFiles() throws {
        try prepare(); _ = try installation.install()
        var expected: [URL:Data] = [:]
        for browser in BrowserSetupInstallation.browsers {
            for name in ["io.codemyriad.cassini","io.codemyriad.cassini.control"] {
                let file = leaf(browser).appendingPathComponent(name + ".json")
                let old = Data(("previous " + browser + name).utf8); try old.write(to:file); expected[file] = old
            }
        }
        XCTAssertThrowsError(try installation.install { index in if index == 5 { throw CocoaError(.fileWriteOutOfSpace) } })
        for (file,old) in expected { XCTAssertEqual(try Data(contentsOf:file),old) }
        for browser in BrowserSetupInstallation.browsers {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:leaf(browser).path).sorted(),[".cassini-connect.lock","io.codemyriad.cassini.control.json","io.codemyriad.cassini.json"])
        }
    }
    func testFreshPartialFailureRemovesEarlierNewManifests() throws {
        try prepare()
        XCTAssertThrowsError(try installation.install { index in if index == 3 { throw CocoaError(.fileWriteOutOfSpace) } })
        for browser in BrowserSetupInstallation.browsers {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:leaf(browser).path),[".cassini-connect.lock"])
        }
    }
    func testSymlinkAndPipeManifestsAreRejectedBeforeAnyPublication() throws {
        try prepare()
        let directory = leaf("Google/Chrome")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        let manifest = directory.appendingPathComponent("io.codemyriad.cassini.control.json")
        let outside = root.appendingPathComponent("untouched"); try Data("keep".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:manifest,withDestinationURL:outside)
        XCTAssertThrowsError(try installation.install()); XCTAssertEqual(try Data(contentsOf:outside),Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("io.codemyriad.cassini.json").path))
        try FileManager.default.removeItem(at:manifest); XCTAssertEqual(mkfifo(manifest.path,0o600),0)
        XCTAssertThrowsError(try installation.install())
    }
    func testSymlinkedBrowserParentCannotRedirectRegistration() throws {
        try prepare(["Google/Chrome"])
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false)
        let chrome = leaf("Google/Chrome").deletingLastPathComponent()
        try FileManager.default.removeItem(at:chrome); try FileManager.default.createSymbolicLink(at:chrome,withDestinationURL:outside)
        XCTAssertThrowsError(try installation.install())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outside.path),[])
    }
    func testMissingOrSymlinkedExecutableCannotBeRegistered() throws {
        try prepare()
        let host = contents.appendingPathComponent("MacOS/cassini-control-host")
        try FileManager.default.removeItem(at:host)
        XCTAssertThrowsError(try installation.install())
        try FileManager.default.createSymbolicLink(at:host,withDestinationURL:contents.appendingPathComponent("MacOS/cassini-browser-host"))
        XCTAssertThrowsError(try installation.install())
    }
    func testNoBrowserProfileMeansNoRegistrationOrProfileCreation() throws {
        XCTAssertThrowsError(try installation.install())
        XCTAssertFalse(FileManager.default.fileExists(atPath:home.path))
    }
    func testConcurrentInstallerCannotInterleavePublications() throws {
        try prepare()
        XCTAssertEqual(try installation.install { index in
            if index == 0 { XCTAssertThrowsError(try self.installation.install()) }
        },8)
        XCTAssertEqual(try installation.install(),8,"Lease must be released after completion")
    }
    func testHardLinkedAndOversizedPreviousManifestsAreRejected() throws {
        try prepare(["Google/Chrome"])
        let directory = leaf("Google/Chrome")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        let file = directory.appendingPathComponent("io.codemyriad.cassini.json")
        let outside = root.appendingPathComponent("other-file"); try Data("keep".utf8).write(to:outside)
        try FileManager.default.linkItem(at:outside,to:file)
        XCTAssertThrowsError(try installation.install())
        try FileManager.default.removeItem(at:file)
        try Data(repeating:0,count:65537).write(to:file)
        XCTAssertThrowsError(try installation.install())
        XCTAssertEqual(try Data(contentsOf:outside),Data("keep".utf8))
    }
}
