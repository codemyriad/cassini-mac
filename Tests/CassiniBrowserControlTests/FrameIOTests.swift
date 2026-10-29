// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
import CassiniKit
@testable import CassiniBrowserControl

final class FrameIOTests: XCTestCase {
    func testFinalBytesArrivingBetweenEmptyReadAndLeaseCheckAreDrained() throws {
        var descriptors: [Int32] = [-1,-1]; XCTAssertEqual(pipe(&descriptors),0)
        let input = descriptors[0], output = descriptors[1]
        defer { close(input); close(output) }
        try FrameIO.prepare(input)
        let packet = Data("{\"race\":true}".utf8)
        XCTAssertEqual(try FrameIO.read(input,cancel:Cancellation(),alive:{
            try? FrameIO.writeFrame(output,data:packet,cancel:Cancellation())
            return false
        }),packet)
    }
    func testBufferedFinalFrameIsReadAfterTheWriterLeaseEnds() throws {
        var descriptors: [Int32] = [-1,-1]; XCTAssertEqual(pipe(&descriptors),0)
        defer { close(descriptors[0]) }
        try FrameIO.prepare(descriptors[0])
        let packet = Data("{\"final\":true}".utf8)
        try FrameIO.writeFrame(descriptors[1],data:packet,cancel:Cancellation())
        close(descriptors[1])
        XCTAssertEqual(try FrameIO.read(descriptors[0],cancel:Cancellation(),alive:{ false }),packet)
        XCTAssertNil(try FrameIO.read(descriptors[0],cancel:Cancellation(),alive:{ false }))
    }
    func testFramedPipeHandlesBodiesLargerThanTheKernelPipeBuffer() throws {
        var descriptors: [Int32] = [-1,-1]
        XCTAssertEqual(pipe(&descriptors),0)
        let input = descriptors[0], output = descriptors[1]
        defer { close(input); close(output) }
        try FrameIO.prepare(input); try FrameIO.prepare(output)
        let payload = Data(("{\"type\":\"future\",\"body\":\"" + String(repeating:"x",count:200000) + "\"}").utf8)
        let cancel = Cancellation(), done = expectation(description:"bounded pipe writer")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            try? FrameIO.writeFrame(output,data:payload,cancel:cancel)
        }
        XCTAssertEqual(try FrameIO.read(input,cancel:cancel,deadline:DispatchTime.now().uptimeNanoseconds + 5_000_000_000),payload)
        wait(for:[done],timeout:5)
    }
    func testNormalizingPreservesValuesAndLexicalNumbersWithoutLineBreaks() throws {
        let raw = Data("{\n\"type\":\"future\",\"integer\":1,\"decimal\":1.0,\"text\":\"line\\nline\"\n}".utf8)
        let normalized = try FrameIO.normalized(raw)
        XCTAssertFalse(normalized.contains(10))
        XCTAssertEqual(try JSONParser.parse(normalized),try JSONParser.parse(raw))
        for bad in ["[]","{\"type\":\"hello\",\"version\":true}","{\"type\":\"hello\",\"version\":1.0}",
                    "{\"type\":\"hello\",\"version\":2}","{\"type\":\"hello\",\"type\":\"status\"}","{\"n\":NaN}"] {
            XCTAssertThrowsError(try FrameIO.normalized(Data(bad.utf8)),bad)
        }
    }
    func testFrameLimitsAndTruncatedHeaderAreRejected() throws {
        for bytes in [Data([0,0,0,0]),Data([1,0,8,0]),Data([1,0]) ] {
            var descriptors: [Int32] = [-1,-1]; XCTAssertEqual(pipe(&descriptors),0)
            defer { close(descriptors[0]) }
            bytes.withUnsafeBytes { buffer in XCTAssertEqual(Darwin.write(descriptors[1],buffer.baseAddress,buffer.count),buffer.count) }
            close(descriptors[1])
            try FrameIO.prepare(descriptors[0])
            XCTAssertThrowsError(try FrameIO.read(descriptors[0],cancel:Cancellation()))
        }
    }
    func testCancellationDoesNotNeedToCloseAnActiveDescriptor() throws {
        var descriptors: [Int32] = [-1,-1]; XCTAssertEqual(pipe(&descriptors),0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        try FrameIO.prepare(descriptors[0])
        let cancel = Cancellation(); cancel.cancel()
        XCTAssertThrowsError(try FrameIO.read(descriptors[0],cancel:cancel))
        XCTAssertNotEqual(fcntl(descriptors[0],F_GETFD),-1)
    }
}
