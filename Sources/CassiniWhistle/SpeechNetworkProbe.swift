// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import Darwin

/// Explicit generated-file test mode only. The caller supplies a listening
/// loopback fixture; EPERM/EACCES proves the packaged worker's sandbox denial.
public enum SpeechNetworkProbe {
    public static func run(arguments: [String]) throws -> Bool {
        guard arguments.count == 2, arguments[0] == "--network-probe", let port = UInt16(arguments[1]), port > 0 else { return false }
        let fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw WhistleFailure.runtime("probe socket failed") }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let code = result == 0 ? 0 : errno
        let data = try JSONSerialization.data(withJSONObject:["networkDenied":result != 0 && [EPERM,EACCES].contains(code),"errno":code,"connected":result == 0])
        try WhistleIO.write(data + Data([10]),to:STDOUT_FILENO)
        return true
    }
}
#endif
