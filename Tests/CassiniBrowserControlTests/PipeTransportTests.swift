// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import Darwin
@testable import CassiniBrowserControl

private final class Peers: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID] = []
    func add(_ id: UUID) { lock.lock(); values.append(id); lock.unlock() }
    func all() -> [UUID] { lock.lock(); defer { lock.unlock() }; return values }
}

final class PipeTransportTests: XCTestCase {
    func testFreshHomeWithoutMusicCanStartTheProtectedBroker() throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at:base) }
        let root = base.appendingPathComponent("FreshHome/Music/.cassini-browser-control")
        let server = BrowserPipeServer(root:root,connected:{ _ in },received:{ peer,data in try peer.send(data) },disconnected:{ _ in })
        try server.start(); defer { server.stop() }
        let client = try PipeEndpoint(root:root,role:.control,browser:nil)
        let packet = Data("{\"fresh\":true}".utf8)
        try client.send(packet); XCTAssertEqual(try client.receive(),packet)
    }
    func testPublishedDirectoryWhoseLeaseWasRemovedIsRetired() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clients = root.appendingPathComponent("clients"), orphan = clients.appendingPathComponent(UUID().uuidString)
        try PipeFiles.directory(clients,create:true); try PipeFiles.directory(orphan,create:true)
        XCTAssertEqual(mkfifo(orphan.appendingPathComponent("request").path,0o600),0)
        let server = BrowserPipeServer(root:root,connected:{ _ in XCTFail("No lease means no peer") },received:{ _,_ in },disconnected:{ _ in })
        try server.start(); defer { server.stop() }
        server.discoverNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path))
    }
    func testServerClosedPeerIsRetiredAndNotReadoptedWhileClientOwnsItsLease() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let peers = Peers(), gone = expectation(description:"closed peer retired")
        let server = BrowserPipeServer(root:root,connected:{ peers.add($0.peer.id) },received:{ peer,_ in peer.close() },disconnected:{ _ in gone.fulfill() })
        try server.start(); defer { server.stop() }
        let client = try PipeEndpoint(root:root,role:.control,browser:nil)
        let folders = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("clients"),includingPropertiesForKeys:nil)
        let folder = try XCTUnwrap(folders.first { UUID(uuidString:$0.lastPathComponent) != nil })
        try client.send(Data("{\"close\":true}".utf8))
        wait(for:[gone],timeout:3)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
        for _ in 0..<3 { server.discoverNow() } // Actual discovery passes, with the lease retained.
        XCTAssertEqual(peers.all().count,1)
        withExtendedLifetime(client) {}
    }
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniPipeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return root
    }
    func testTwoPeersWithTheSameBrowserAndTabKeepDistinctConnections() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let peers = Peers()
        let server = BrowserPipeServer(root:root,connected:{ peers.add($0.peer.id) },received:{ peer,data in try peer.send(data) },disconnected:{ _ in })
        try server.start(); defer { server.stop() }
        let first = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        let second = try PipeEndpoint(root:root,role:.control,browser:"Chrome")
        defer { first.stop(); second.stop() }
        let a = Data("{\"type\":\"future\",\"tabId\":2,\"marker\":\"first\"}".utf8)
        let b = Data("{\"type\":\"future\",\"tabId\":2,\"marker\":\"second\"}".utf8)
        try first.send(a); try second.send(b)
        XCTAssertEqual(try first.receive(),try FrameIO.normalized(a))
        XCTAssertEqual(try second.receive(),try FrameIO.normalized(b))
        XCTAssertEqual(Set(peers.all()).count,2)
    }
    func testSlowFragmentedPeerDoesNotBlockAnotherOrLoseItsPartialFrame() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clock = TransportReadClock(), entered = expectation(description:"Reader consumed partial header"), release = DispatchSemaphore(value:0)
        let server = BrowserPipeServer(root:root,connected:{ _ in },received:{ peer,data in try peer.send(data) },disconnected:{ _ in })
        server.readClock = { clock.now() }
        server.readProgress = { count in
            guard count == 2, clock.claimPartial() else { return }
            entered.fulfill()
            if release.wait(timeout:.now() + 10) == .timedOut {
                XCTFail("Timed out waiting to release the partial reader")
            }
        }
        try server.start(); defer { release.signal(); server.stop() }
        let first = try PipeEndpoint(root:root,role:.control,browser:nil)
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("clients"),includingPropertiesForKeys:nil).first { UUID(uuidString:$0.lastPathComponent) != nil })
        let second = try PipeEndpoint(root:root,role:.control,browser:nil)
        defer { first.stop(); second.stop() }
        let fd = try PipeFiles.openFile(folder.appendingPathComponent("request"),flags:O_WRONLY,kind:S_IFIFO)
        defer { close(fd) }
        let payload = Data(("{\"type\":\"future\",\"body\":\"" + String(repeating:"x",count:100000) + "\"}").utf8)
        var size = UInt32(payload.count).littleEndian
        let header = withUnsafeBytes(of:&size) { Data($0) }
        try FrameIO.write(fd,bytes:header.prefix(2),cancel:Cancellation())
        guard XCTWaiter.wait(for:[entered],timeout:3) == .completed else {
            XCTFail("Reader did not consume the partial header")
            return
        }
        let other = Data("{\"type\":\"future\",\"body\":\"independent\"}".utf8)
        try second.send(other)
        let secondReply = try second.receive(deadline:DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
        XCTAssertEqual(secondReply,try FrameIO.normalized(other))
        clock.advance(350_000_000) // Cross the former 250 ms retry boundary virtually.
        release.signal()
        try FrameIO.write(fd,bytes:header.suffix(2) + payload,cancel:Cancellation())
        let firstReply = try first.receive(deadline:DispatchTime.now().uptimeNanoseconds + 6_000_000_000)
        XCTAssertEqual(firstReply,try FrameIO.normalized(payload))
    }
    func testPeerDeathBeforeItsFirstMessageReleasesTheServerSide() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let gone = expectation(description:"kernel lease retirement")
        let server = BrowserPipeServer(root:root,connected:{ _ in },received:{ _,_ in XCTFail("No packet expected") },disconnected:{ _ in gone.fulfill() })
        try server.start(); defer { server.stop() }
        var client: PipeEndpoint? = try PipeEndpoint(root:root,role:.control,browser:nil)
        XCTAssertNotNil(client); client = nil
        wait(for:[gone],timeout:3)
    }
    func testStoppedServerClosesAnIdlePeerWithoutACommand() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let waiting = expectation(description:"Idle server reader entered its wait")
        waiting.assertForOverFulfill = false
        let server = BrowserPipeServer(root:root,connected:{ _ in },received:{ _,_ in },disconnected:{ _ in })
        server.readProgress = { if $0 == 0 { waiting.fulfill() } }
        try server.start(); defer { server.stop() }
        let client = try PipeEndpoint(root:root,role:.control,browser:nil)
        wait(for:[waiting],timeout:3)
        server.stop()
        XCTAssertNil(try client.receive())
    }
    func testBackpressureDisconnectsOnlyTheSlowPeer() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let gone = expectation(description:"slow peer disconnected"), blocked = Peers()
        let large = Data(("{\"type\":\"future\",\"body\":\"" + String(repeating:"x",count:500000) + "\"}").utf8)
        let server = BrowserPipeServer(root:root,connected:{ _ in },received:{ peer,data in
            if try FrameIO.normalized(data) == Data("{\"block\":true}".utf8) {
                blocked.add(peer.peer.id)
                for _ in 0..<5 { try peer.send(large) }
            } else { try peer.send(data) }
        },disconnected:{ peer in if blocked.all().contains(peer.id) { gone.fulfill() } })
        try server.start(); defer { server.stop() }
        let slow = try PipeEndpoint(root:root,role:.control,browser:nil)
        let other = try PipeEndpoint(root:root,role:.control,browser:nil)
        try slow.send(Data("{\"block\":true}".utf8))
        let packet = Data("{\"unaffected\":true}".utf8)
        try other.send(packet)
        XCTAssertEqual(try other.receive(),packet)
        wait(for:[gone],timeout:3)
        // The healthy peer remains usable after the other one's writer closes.
        try other.send(packet); XCTAssertEqual(try other.receive(),packet)
    }
    func testBrokerLeasePreventsASecondServerUntilOldPeersRetire() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let first = BrowserPipeServer(root:root,connected:{ _ in },received:{ _,_ in },disconnected:{ _ in })
        let second = BrowserPipeServer(root:root,connected:{ _ in },received:{ _,_ in },disconnected:{ _ in })
        try first.start(); defer { first.stop(); second.stop() }
        let client = try PipeEndpoint(root:root,role:.control,browser:nil)
        XCTAssertThrowsError(try second.start())
        let retired = expectation(description:"Old server released its lease after peer retirement")
        first.stopCompleted = { retired.fulfill() }
        first.stop()
        XCTAssertNil(try client.receive())
        wait(for:[retired],timeout:3)
        try second.start()
    }
    func testAbandonedStagingIsRemovedButLiveStagingIsPreserved() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let clients = root.appendingPathComponent("clients")
        try PipeFiles.directory(clients,create:true)
        let stale = clients.appendingPathComponent(".pending-" + UUID().uuidString)
        let live = clients.appendingPathComponent(".pending-" + UUID().uuidString)
        for folder in [stale,live] { try PipeFiles.directory(folder,create:true) }
        let fd = try PipeFiles.openFile(live.appendingPathComponent("lease"),flags:O_RDWR,create:true)
        defer { close(fd) }
        XCTAssertEqual(flock(fd,LOCK_EX | LOCK_NB),0)
        for folder in [stale,live] {
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-60)],ofItemAtPath:folder.path)
        }
        let server = BrowserPipeServer(root:root,connected:{ _ in },received:{ _,_ in },disconnected:{ _ in })
        try server.start(); defer { server.stop() }
        server.discoverNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath:stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:live.appendingPathComponent("lease").path))
    }
    func testUnsafeRootAndInactiveBrokerAreRejectedWithoutCreatingClients() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let missing = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try PipeEndpoint(root:missing,role:.control,browser:nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
        let unsafe = root.appendingPathComponent("world-readable")
        try FileManager.default.createDirectory(at:unsafe,withIntermediateDirectories:false)
        XCTAssertEqual(chmod(unsafe.path,0o755),0)
        XCTAssertThrowsError(try PipeEndpoint(root:unsafe,role:.control,browser:nil))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
        XCTAssertThrowsError(try PipeEndpoint(root:alias,role:.control,browser:nil))
    }
}

private final class TransportReadClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000
    private var partial = false
    func claimPartial() -> Bool { lock.withLock { if partial { return false }; partial = true; return true } }
    func now() -> UInt64 { lock.withLock { value } }
    func advance(_ ns: UInt64) { lock.withLock { value += ns } }
}
