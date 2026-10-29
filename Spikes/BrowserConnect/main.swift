// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniBrowserSetup

private final class Reply: @unchecked Sendable {
    let done = DispatchSemaphore(value:0)
    private let lock = NSLock()
    private var result: (Int,NSError?)?
    func set(_ count: Int, _ error: NSError?) { lock.lock(); defer { lock.unlock() }; if result == nil { result = (count,error); done.signal() } }
    func get() -> (Int,NSError?)? { lock.lock(); defer { lock.unlock() }; return result }
}
do {
    guard CommandLine.arguments.count == 2 else { throw BrowserSetupError.unsafePath }
    let home = URL(fileURLWithPath:CommandLine.arguments[1])
    let file = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/client-must-not-write")
    let fd = open(file.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
    let denied = fd < 0 && [EACCES,EPERM].contains(errno)
    if fd >= 0 { close(fd); unlink(file.path) }
    let connection = NSXPCConnection(serviceName:BrowserSetupInstallation.serviceName)
    connection.remoteObjectInterface = NSXPCInterface(with:CassiniBrowserSetupService.self)
    let reply = Reply()
    connection.invalidationHandler = { reply.set(0,NSError(domain:"probe-invalidated",code:1)) }
    connection.resume()
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.set(0,$0 as NSError) }) as? CassiniBrowserSetupService else { throw BrowserSetupError.unavailable }
    let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
    let audio = try contents.appendingPathComponent("MacOS/cassini-browser-host").bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
    let control = try contents.appendingPathComponent("MacOS/cassini-control-host").bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
    let wrong = try Bundle.main.executableURL!.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
    let rejected = Reply()
    proxy.connect(audioHostBookmark:wrong,controlHostBookmark:control) { rejected.set($0,$1) }
    guard rejected.done.wait(timeout:.now() + 10) == .success, rejected.get()?.1 != nil else { throw BrowserSetupError.invalidHost }
    proxy.connect(audioHostBookmark:audio,controlHostBookmark:control) { reply.set($0,$1) }
    guard reply.done.wait(timeout:.now() + 20) == .success, let (count,error) = reply.get() else { throw BrowserSetupError.unavailable }
    connection.invalidationHandler = nil; connection.invalidate()
    if let error { throw error }
    let result: [String:Any] = ["manifestsWritten":count,"parentWriteDenied":denied,"wrongHostBookmarkRejected":true]
    try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:result,options:.sortedKeys) + Data([10]))
} catch { try? FileHandle.standardError.write(contentsOf:Data((String(describing:error)+"\n").utf8)); exit(78) }
