// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniBrowserSetupProbe

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String) { lock.lock(); defer { lock.unlock() }; if self.value == nil { self.value = value } }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
private func deniedWrite(_ url: URL) -> Bool {
    let fd = open(url.path,O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW,0o600)
    if fd >= 0 { close(fd); unlink(url.path); return false }
    return errno == EACCES || errno == EPERM
}
do {
    guard CommandLine.arguments.count == 3, let port = UInt16(CommandLine.arguments[2]),
          let identifier = Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadInvalidFileName) }
    let home = URL(fileURLWithPath:CommandLine.arguments[1])
    let target = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/client-must-not-write")
    let parentDenied = deniedWrite(target)
    let connection = NSXPCConnection(serviceName:identifier + ".setup")
    connection.remoteObjectInterface = NSXPCInterface(with:BrowserSetupProbeProtocol.self)
    let outcome = Outcome(), done = DispatchSemaphore(value:0)
    connection.invalidationHandler = { outcome.set("{\"error\":\"connection invalidated\"}"); done.signal() }
    connection.resume()
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        outcome.set("{\"error\":\"XPC transport failed\"}"); done.signal()
        FileHandle.standardError.write(Data((String(describing:error) + "\n").utf8))
    } as? BrowserSetupProbeProtocol
    guard let proxy else { throw CocoaError(.coderInvalidValue) }
    proxy.probe(home:home.path,port:port) { reply in outcome.set(reply); done.signal() }
    guard done.wait(timeout:.now() + 20) == .success, let reply = outcome.get(), let data = reply.data(using:.utf8),
          var report = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw CocoaError(.xpcConnectionInterrupted) }
    connection.invalidationHandler = nil; connection.invalidate()
    report["parentWriteDenied"] = parentDenied
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:.sortedKeys) + Data([10]))
} catch {
    FileHandle.standardError.write(Data((String(describing:error) + "\n").utf8)); exit(78)
}
