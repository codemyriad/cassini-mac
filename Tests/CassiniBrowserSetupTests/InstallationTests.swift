// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
@_spi(Testing) import CassiniBrowserSetup

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
    func testRegistersBothHostsWithPinnedOriginAndPrivateModesInAllFourBrowsers() throws {
        try prepare()
        XCTAssertEqual(try installation.install(),8)
        for browser in BrowserSetupInstallation.browsers {
            for (name,executable) in [("com.codemyriad.cassini","cassini-browser-host"),("com.codemyriad.cassini.control","cassini-control-host")] {
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
    func testRepeatConnectRepairsAStalePathAndSkipsBrowsersThatNeverRan() throws {
        try prepare(["Google/Chrome"])
        XCTAssertEqual(try installation.install(),2)
        let file = leaf("Google/Chrome").appendingPathComponent("com.codemyriad.cassini.json")
        try Data("old app location".utf8).write(to:file)
        XCTAssertEqual(try installation.install(),2)
        XCTAssertTrue(try String(contentsOf:file,encoding:.utf8).contains("cassini-browser-host"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:leaf("Chromium").deletingLastPathComponent().path))
    }
    func testFailureRollsBackEveryPreviouslyPublishedManifestAndLeavesNoStagingFiles() throws {
        try prepare(); _ = try installation.install()
        var expected: [URL:Data] = [:]
        for browser in BrowserSetupInstallation.browsers {
            for name in ["com.codemyriad.cassini","com.codemyriad.cassini.control"] {
                let file = leaf(browser).appendingPathComponent(name + ".json")
                let old = Data(("previous " + browser + name).utf8); try old.write(to:file); expected[file] = old
            }
        }
        XCTAssertThrowsError(try installation.install { index in if index == 5 { throw CocoaError(.fileWriteOutOfSpace) } })
        for (file,old) in expected { XCTAssertEqual(try Data(contentsOf:file),old) }
        for browser in BrowserSetupInstallation.browsers {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:leaf(browser).path).sorted(),[".cassini-connect.lock","com.codemyriad.cassini.control.json","com.codemyriad.cassini.json"])
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
        let manifest = directory.appendingPathComponent("com.codemyriad.cassini.control.json")
        let outside = root.appendingPathComponent("untouched"); try Data("keep".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:manifest,withDestinationURL:outside)
        XCTAssertThrowsError(try installation.install()); XCTAssertEqual(try Data(contentsOf:outside),Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("com.codemyriad.cassini.json").path))
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
        let file = directory.appendingPathComponent("com.codemyriad.cassini.json")
        let outside = root.appendingPathComponent("other-file"); try Data("keep".utf8).write(to:outside)
        try FileManager.default.linkItem(at:outside,to:file)
        XCTAssertThrowsError(try installation.install())
        try FileManager.default.removeItem(at:file)
        try Data(repeating:0,count:65537).write(to:file)
        XCTAssertThrowsError(try installation.install())
        XCTAssertEqual(try Data(contentsOf:outside),Data("keep".utf8))
    }
}
