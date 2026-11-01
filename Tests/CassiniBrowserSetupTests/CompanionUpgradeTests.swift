// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
import CassiniBrowserSetup

struct CompanionUpgradeTests {
    @Test func actual022RuntimeUpgradesToReviewed028AndThenStaysUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CassiniCompanionUpgrade-"+UUID().uuidString)
        let source = root.appendingPathComponent("source"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let fixture = try #require(Bundle.module.url(forResource:"runtime",withExtension:"tar.gz",subdirectory:"Fixtures/Companion022"))
        let packed = try Data(contentsOf:fixture)
        #expect(SHA256.hash(data:packed).map { String(format:"%02x",$0) }.joined() == "5aa70f6a37f8e18bf4340746434f09680d725269ae31b0be621e8418d07bc157")
        try run("/usr/bin/tar",["-xzf",fixture.path,"-C",source.path])
        let pin = try #require(Bundle.module.url(forResource:"UPSTREAM",withExtension:"json",subdirectory:"Fixtures/Companion022"))
        let provenance = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:pin)) as? [String:Any])
        #expect(provenance["commit"] as? String == "bb13da92fa8c3192bb6d9b8444acd3197c772d62")
        let oldFiles = try #require(provenance["filesSHA256"] as? [String:String]); #expect(oldFiles.count == 17)
        for (name,hash) in oldFiles {
            #expect(SHA256.hash(data:try Data(contentsOf:source.appendingPathComponent(name))).map { String(format:"%02x",$0) }.joined() == hash)
        }
        let installer = LocalCompanionInstallation(home:home,source:source)
        let first = try install(installer,stage:"real 0.2.2 install")
        #expect(first.updated && first.version == "0.2.2")
        let background = try Data(contentsOf:installer.destination.appendingPathComponent("background.js"))
        let control = try Data(contentsOf:installer.destination.appendingPathComponent("app-control.js"))
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Use the exact production resource bundler, not a fabricated manifest
        // or installer mock. The home is private and no browser is launched.
        let program = "import os,runpy,sys; os.umask(0); sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name='__main__')"
        try run("/usr/bin/env",["python3","-c",program,repository.appendingPathComponent("scripts/bundle-browser-companion.py").path,source.path])
        let upgraded = try install(installer,stage:"real 0.2.9 upgrade")
        #expect(upgraded.updated && upgraded.version == "0.2.9")
        #expect(try Data(contentsOf:installer.destination.appendingPathComponent("background.js")) != background)
        #expect(try Data(contentsOf:installer.destination.appendingPathComponent("app-control.js")) != control)
        #expect(try String(contentsOf:installer.destination.appendingPathComponent("PROTOCOL_COMMIT.txt"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines) == "a1be3bcf2678a308d5b17c5b09b1a57c1c8d5635")
        var identities: [String:NSNumber] = [:], dates: [String:Date] = [:]
        let files = try #require(FileManager.default.enumerator(atPath:source.path))
        var count = 0
        for case let name as String in files {
            let file = source.appendingPathComponent(name)
            guard try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else { continue }
            let mode = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber
            #expect(try #require(mode).intValue & 0o022 == 0,"Bundling is safe even with a permissive build umask")
            let installed = installer.destination.appendingPathComponent(name)
            #expect(try Data(contentsOf:installed) == Data(contentsOf:file)); count += 1
            let attributes = try FileManager.default.attributesOfItem(atPath:installed.path)
            identities[name] = try #require(attributes[.systemFileNumber] as? NSNumber)
            dates[name] = try #require(attributes[.modificationDate] as? Date)
        }
        #expect(count == 17)
        #expect(try !installer.install().updated)
        for (name,inode) in identities {
            let attributes = try FileManager.default.attributesOfItem(atPath:installer.destination.appendingPathComponent(name).path)
            #expect(attributes[.systemFileNumber] as? NSNumber == inode)
            #expect(attributes[.modificationDate] as? Date == dates[name])
        }
    }
    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath:path); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
    }
    private func install(_ value: LocalCompanionInstallation, stage: String) throws -> LocalCompanionInstallation.Result {
        do { return try value.install() }
        catch { throw NSError(domain:"CompanionUpgrade",code:1,userInfo:[NSLocalizedDescriptionKey:stage+": "+String(describing:error)]) }
    }
}
