import Foundation
import CryptoKit
import Testing
@testable import CassiniWhistle

@Suite struct WhistlePrivacyTests {
    @Test func workerEnvironmentOverridesUnsafeParentValues() throws {
        let safe = WhistleEnvironment.worker(["NEEDLE_TELEMETRY": "1", "DO_NOT_TRACK": "0", "ORT_DISABLE_TELEMETRY": "0", "PATH": "/usr/bin"])
        try WhistleEnvironment.validate(safe)
        #expect(safe["PATH"] == "/usr/bin")
        for key in WhistleEnvironment.required.keys {
            var invalid = safe; invalid.removeValue(forKey: key)
            #expect(throws: WhistleFailure.self) { try WhistleEnvironment.validate(invalid) }
            invalid[key] = "wrong"
            #expect(throws: WhistleFailure.self) { try WhistleEnvironment.validate(invalid) }
        }
    }
    @Test func sharedPublicDomainFixtureBytesAreUnchanged() throws {
        let expected = ["jfk.wav": "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e", "jfk.txt": "8d7d44eb38e4e38626c14bbadbc28fc67c6cd8b49b688f6c4da79402eb4bcfce"]
        for (name, hash) in expected {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            #expect(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() == hash)
        }
    }
}
