// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Kernel process start time prevents a reused PID from inheriting a user's Stop.
/// This is local host metadata, never a browser-extension wire field.
public struct BrowserInstance: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt32
    init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt32 = 0) {
        precondition(pid > 1 && startSeconds > 0 && startMicroseconds < 1_000_000)
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
    private enum CodingKeys: String, CodingKey { case pid, startSeconds, startMicroseconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        let pid = try c.decode(Int32.self,forKey:.pid), seconds = try c.decode(UInt64.self,forKey:.startSeconds)
        let micros = try c.decode(UInt32.self,forKey:.startMicroseconds)
        guard pid > 1, seconds > 0, micros < 1_000_000 else {
            throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid browser instance"))
        }
        self.init(pid:pid,startSeconds:seconds,startMicroseconds:micros)
    }
    static func process(_ pid: Int32) -> BrowserInstance? {
        var info = proc_bsdinfo()
        guard pid > 1, proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout.size(ofValue:info))) == MemoryLayout.size(ofValue:info),
              info.pbi_uid == getuid(), info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { return nil }
        return .init(pid:pid,startSeconds:info.pbi_start_tvsec,startMicroseconds:UInt32(info.pbi_start_tvusec))
    }
    static var parentBrowser: BrowserInstance? {
        let pid = getppid()
        guard let before = process(pid) else { return nil }
        var bytes = [CChar](repeating:0,count:4096)
        let count = bytes.withUnsafeMutableBufferPointer { proc_pidpath(pid,$0.baseAddress,UInt32($0.count)) }
        guard count > 0, isBrowserPath(String(cString:bytes)), getppid() == pid, process(pid) == before else { return nil }
        return before
    }
    static func isBrowserPath(_ path: String) -> Bool {
        ["Google Chrome.app","Google Chrome for Testing.app","Chromium.app","Microsoft Edge.app","Brave Browser.app"]
            .contains { path.contains("/"+$0+"/Contents/MacOS/") }
    }
    /// A sandbox may deny inspection. Unknown is not evidence of process exit.
    public var isAlive: Bool? {
        if let current = Self.process(pid) { return current == self }
        if kill(pid,0) != 0 && errno == ESRCH { return false }
        return nil
    }
}
