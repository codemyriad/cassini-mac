// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
@testable import CassiniBrowserControl

final class ControlHostTests: XCTestCase {
    private func exercise(_ action: (Process,Pipe,Pipe,BrowserPipeServer) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniHostTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let connected = expectation(description:"private host handshake")
        let server = BrowserPipeServer(root:root,connected:{ _ in connected.fulfill() },received:{ peer,data in try peer.send(data) },disconnected:{ _ in })
        try server.start(); defer { server.stop() }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("cassini-control-host")
        process.environment = ["CASSINI_CONTROL_PIPE_ROOT":root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let finished = expectation(description:"native host exits without a stop command")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        }
        wait(for:[connected],timeout:4)
        try action(process,input,output,server)
        wait(for:[finished],timeout:5)
        XCTAssertFalse(process.isRunning)
    }
    func testNativeHostRoundTripAndInputEOFReleaseItsPeer() throws {
        try exercise { process,input,output,_ in
            try FrameIO.prepare(output.fileHandleForReading.fileDescriptor)
            let packet = Data("{\"type\":\"hello\",\"version\":1}".utf8)
            try FrameIO.writeFrame(input.fileHandleForWriting.fileDescriptor,data:packet,cancel:Cancellation())
            XCTAssertEqual(try FrameIO.read(output.fileHandleForReading.fileDescriptor,cancel:Cancellation(),deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000),packet)
            try input.fileHandleForWriting.close()
            assertExit(process,status:0)
        }
    }
    func testBrokerShutdownReleasesAnIdleHostWithoutClosingBrowserInput() throws {
        try exercise { process,input,output,server in
            // Broker acceptance precedes the client's final FIFO open. Prove
            // that the host is fully connected before testing idle shutdown;
            // otherwise stopping here can race initialization, not idle I/O.
            try FrameIO.prepare(output.fileHandleForReading.fileDescriptor)
            let packet = Data("{\"type\":\"hello\",\"version\":1}".utf8)
            try FrameIO.writeFrame(input.fileHandleForWriting.fileDescriptor,data:packet,cancel:Cancellation())
            XCTAssertEqual(try FrameIO.read(output.fileHandleForReading.fileDescriptor,cancel:Cancellation(),deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000),packet)
            server.stop()
            assertExit(process,status:0)
        }
    }
    func testMalformedNativeLengthFailsInsteadOfBeingRelayed() throws {
        try exercise { process,input,_,_ in
            try input.fileHandleForWriting.write(contentsOf:Data([0,0,0,0]))
            assertExit(process,status:78)
        }
    }
    private func assertExit(_ process: Process, status: Int32?, file: StaticString = #filePath, line: UInt = #line) {
        let limit = Date().addingTimeInterval(4)
        while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval:0.01) }
        XCTAssertFalse(process.isRunning,file:file,line:line)
        if !process.isRunning, let status { XCTAssertEqual(process.terminationStatus,status,file:file,line:line) }
    }
}
