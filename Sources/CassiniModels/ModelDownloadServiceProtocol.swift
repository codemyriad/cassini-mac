// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public extension ModelPin {
    static let parakeetUltra = Self(id:"parakeet-ultra-0.6b-int8",sourceSHA256:"18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9")
}
/// Private bundled XPC service. It receives only a scoped model-data directory;
/// no meeting/audio/transcript data or arbitrary network URL crosses this API.
@objc public protocol CassiniModelDownloadService {
    func install(destinationBookmark: Data, expectedDirectory: String, reply: @escaping @Sendable (String?,NSError?) -> Void)
    func cancel()
    #if DEBUG
    func probeEnvironment(port: UInt16, destinationBookmark: Data, expectedDirectory: String, reply: @escaping @Sendable (Bool,Bool,NSError?) -> Void)
    #endif
}
@objc public protocol CassiniModelDownloadProgress {
    func progress(received: UInt64, total: UInt64, installed: Bool)
}
