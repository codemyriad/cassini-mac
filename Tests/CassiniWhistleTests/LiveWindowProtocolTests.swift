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

extension LiveWindowProtocolTests {
    func testWorkerWaitsForReadyAndRejectsMismatchedID() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try """
        #!/bin/sh
        printf '%s\\n' '{"ready":true}'
        IFS= read -r request
        printf '%s\\n' '{"id":99,"failed":false,"transcript":{"text":"","language":"en"}}'
        """.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let worker = WhistleSubprocess.WindowSession(executable: path, arguments: [], environment: [:])
        do {
            _ = try await worker.decode([0.5])
            XCTFail("Accepted a response for a different request")
        } catch WhistleSubprocess.WindowSession.RequestFailure.invalidResponse {
            // The fake child acknowledged startup and wrote an answer for the wrong request.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await worker.close()
    }
}

extension LiveWindowProtocolTests {
    func testRejectedWirePCMDoesNotDiscardTheNextRequest() throws {
        let input = Pipe(), output = Pipe()
        let valid = try LiveWindowProtocol.Request(id: 2, samples: [0.25, -0.5])
        let encoder = JSONEncoder()
        let malformed = Data(#"{"id":1,"pcm":"AAAA"}"#.utf8)
        let inputData = malformed + Data([10]) + (try encoder.encode(valid)) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: inputData)
        try input.fileHandleForWriting.close()
        try LiveWindowProtocol.serve(input: input.fileHandleForReading.fileDescriptor,
                                     output: output.fileHandleForWriting.fileDescriptor) { samples in
            XCTAssertEqual(samples, [0.25, -0.5])
            return WhistleTranscript(text: "hello", language: "en",
                                     words: [.init(word: "hello", start: 0, end: 0.0001, probability: 1)])
        }
        try output.fileHandleForWriting.close()
        let lines = output.fileHandleForReading.readDataToEndOfFile().split(separator: 10)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, Data(#"{"ready":true}"#.utf8))
        let replies = try lines.dropFirst().map {
            try JSONDecoder().decode(LiveWindowProtocol.Response.self, from: Data($0))
        }
        XCTAssertEqual(replies.map(\.id), [1, 2])
        XCTAssertEqual(replies.map(\.failed), [true, false])
        XCTAssertEqual(replies.last?.transcript?.words?.first?.end, 0.0001)
        let largest = try LiveWindowProtocol.Request(id: 3, samples: Array(repeating: 0, count: LiveWindowProtocol.sampleLimit))
        XCTAssertLessThan(try encoder.encode(largest).count, LiveWindowProtocol.lineLimit)
    }
}
