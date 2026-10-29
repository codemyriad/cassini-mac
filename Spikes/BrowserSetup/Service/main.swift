// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CassiniBrowserSetupProbe

private func deniedWrite(_ url: URL) -> Bool {
    let fd = open(url.path,O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW,0o600)
    if fd >= 0 { close(fd); unlink(url.path); return false }
    return errno == EACCES || errno == EPERM
}
final class Probe: NSObject, BrowserSetupProbeProtocol {
    func probe(home: String, port: UInt16, reply: @escaping @Sendable (String) -> Void) {
        var result: [String:Any] = [:]
        do {
            guard let expected = Bundle.main.object(forInfoDictionaryKey:"ProbeFixtureHome") as? String,
                  let executable = Bundle.main.object(forInfoDictionaryKey:"ProbeHostExecutable") as? String,
                  home == expected, home.contains("/build/browser-setup-spike-") else { throw CocoaError(.fileReadNoPermission) }
            let root = URL(fileURLWithPath:home)
            let browsers = ["Google/Chrome","Chromium","Microsoft Edge","BraveSoftware/Brave-Browser"]
            var count = 0
            for browser in browsers {
                let directory = root.appendingPathComponent("Library/Application Support/" + browser + "/NativeMessagingHosts")
                // The harness creates parent directories, never user profiles.
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                for name in ["io.codemyriad.cassini","io.codemyriad.cassini.control"] {
                    let manifest: [String:Any] = ["name":name,"description":"Generated Cassini setup probe","type":"stdio","path":executable,
                        "allowed_origins":["chrome-extension://pcafdaahfhjiolfpfnlhmljfgoabbaij/"]]
                    let file = directory.appendingPathComponent(name + ".json")
                    try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:file,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                    count += 1
                }
            }
            result["manifestsWritten"] = count
            result["outsideLeafWriteDenied"] = deniedWrite(root.appendingPathComponent("Library/Application Support/Google/Chrome/not-a-host-manifest"))
            let fd = socket(AF_INET,SOCK_STREAM,0)
            guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            result["helperNetworkDenied"] = connected == -1 && [EPERM,EACCES].contains(errno)
        } catch { result["error"] = String(describing:error) }
        let data = try! JSONSerialization.data(withJSONObject:result,options:.sortedKeys)
        reply(String(decoding:data,as:UTF8.self))
    }
}
final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with:BrowserSetupProbeProtocol.self)
        connection.exportedObject = Probe(); connection.resume(); return true
    }
}
let listener = NSXPCListener.service(), delegate = Listener()
listener.delegate = delegate; listener.resume()
