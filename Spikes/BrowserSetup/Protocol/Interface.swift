// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Fixture-only transport, not the production installer API.
@objc(CassiniBrowserSetupProbe) public protocol BrowserSetupProbeProtocol {
    func probe(home: String, port: UInt16, reply: @escaping @Sendable (String) -> Void)
}
