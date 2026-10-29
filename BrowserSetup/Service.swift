// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniBrowserSetup

final class BrowserSetupConnection: NSObject, CassiniBrowserSetupService, @unchecked Sendable {
    private static let queue = DispatchQueue(label:"com.codemyriad.cassini.browser-install")
    func connect(audioHostBookmark: Data, controlHostBookmark: Data, reply: @escaping @Sendable (Int,NSError?) -> Void) {
        Self.queue.async {
            do {
                guard var home = BrowserSetupInstallation.accountHome else { throw BrowserSetupError.unavailable }
                #if DEBUG
                // Only signed fixture metadata chooses a generated home. The
                // production RPC has no path/command arguments, even in Debug.
                if let fixture = Bundle.main.object(forInfoDictionaryKey:"CassiniSetupFixtureHome") as? String {
                    guard fixture.contains("/build/browser-connect-fixture-"), fixture.hasPrefix(home.path + "/") else { throw BrowserSetupError.unsafePath }
                    home = URL(fileURLWithPath:fixture,isDirectory:true)
                }
                #endif
                let contents = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                let audio = try HostAccess(audioHostBookmark,expected:contents.appendingPathComponent("MacOS/cassini-browser-host"))
                let control = try HostAccess(controlHostBookmark,expected:contents.appendingPathComponent("MacOS/cassini-control-host"))
                defer { withExtendedLifetime((audio,control)) {} }
                let count = try BrowserSetupInstallation(home:home,contents:contents).install()
                reply(count,nil)
            } catch {
                #if DEBUG
                reply(0,NSError(domain:"com.codemyriad.cassini.browser-setup",code:1,userInfo:[NSLocalizedDescriptionKey:String(describing:error)]))
                #else
                reply(0,NSError(domain:"com.codemyriad.cassini.browser-setup",code:1))
                #endif
            }
        }
    }
}
private final class HostAccess {
    let url: URL
    private let started: Bool
    init(_ bookmark: Data, expected: URL) throws {
        var stale = false
        url = try URL(resolvingBookmarkData:bookmark,options:[.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
        guard !stale, url.isFileURL, url.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path else { throw BrowserSetupError.invalidHost }
        started = url.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}
final class BrowserSetupListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with:CassiniBrowserSetupService.self)
        connection.exportedObject = BrowserSetupConnection()
        connection.resume(); return true
    }
}
