import Foundation
import XCTest
import CassiniWhistle

final class LiveWindowProtocolTests: XCTestCase {
    func testWindowPreservesSampleBitsAndRejectsInvalidInput() throws {
        let samples: [Float] = [-1, -0.0, .leastNonzeroMagnitude, 0.12345678, 1]
        let request = try LiveWindowProtocol.Request(id: 7, samples: samples)
        let decoded = try JSONDecoder().decode(LiveWindowProtocol.Request.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.id, 7)
        XCTAssertEqual(try decoded.samples().map(\.bitPattern), samples.map(\.bitPattern))
        XCTAssertThrowsError(try LiveWindowProtocol.Request(id: 8, samples: [.nan]))
        XCTAssertThrowsError(try LiveWindowProtocol.Request(
            id: 9, samples: Array(repeating: 0, count: LiveWindowProtocol.sampleLimit + 1)
        ))
    }
}
