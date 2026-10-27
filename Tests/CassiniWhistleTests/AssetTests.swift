// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import Testing
@testable import CassiniWhistle

@Suite struct WhistleAssetTests {
    @Test func compiledSourcePinsMatchPublication() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pin = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Whistle/pins.json"))) as! [String: Any]
        let artifacts = pin["artifacts"] as! [[String: Any]]
        #expect(artifacts.first { $0["name"] as? String == "whistle.cact" }?["sha256"] as? String == WhistlePins.model)
        let cpus: [String: UInt32] = ["arm64": 0x0100000c, "x86_64": 0x01000007]
        for entry in artifacts {
            if let arch = entry["arch"] as? String { #expect(WhistlePins.libraries[cpus[arch]!] == entry["memberSha256"] as? String) }
        }
    }
    @Test func untrustedAndTruncatedLibrariesAreRejectedBeforeLoading() {
        for bytes in [Data(), Data(repeating: 0, count: 100), Data([0xca,0xfe,0xba,0xbe,0,0,0,2])] {
            #expect(throws: WhistleFailure.self) { try WhistleAssets.verifySourceLibrary(bytes) }
        }
    }
    @Test func liveEnvironmentReflectsLateNativeMutation() throws {
        let key = "NEEDLE_TELEMETRY"
        let previous = getenv(key).map { String(cString: $0) }
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        _ = ProcessInfo.processInfo.environment
        setenv(key, "1", 1)
        #expect(throws: WhistleFailure.self) { try WhistleEnvironment.validateLive() }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CASSINI_WHISTLE_TEST_ASSETS"] != nil))
struct WhistleAssetIntegrationTests {
    @Test func modelStorageSurvivesCallsAndOwnershipIsExclusive() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["CASSINI_WHISTLE_TEST_ASSETS"])
        let assets = try WhistleAssets.pinned(directory: URL(fileURLWithPath: directory))
        let wav = try #require(Bundle.module.url(forResource: "jfk.wav", withExtension: nil, subdirectory: "Fixtures"))
        var engine: WhistleEngine? = try WhistleEngine(assets: assets)
        #expect(throws: WhistleFailure.self) { try WhistleEngine(assets: assets) }
        let first = try engine!.transcribe(wav: wav)
        let churn = Data(repeating: 17, count: 4_000_000)
        #expect(churn.count == 4_000_000)
        #expect(try engine!.transcribe(wav: wav).text == first.text)
        engine = nil
        let replacement = try WhistleEngine(assets: assets)
        #expect(try replacement.transcribe(wav: wav).text == first.text)
    }
}
