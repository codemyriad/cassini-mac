// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public extension ModelPin {
    static let parakeetUltra = Self(id:"parakeet-ultra-0.6b-int8",sourceSHA256:"50c15b94ea9cb1c2f8dbcdcbc0f15b450169154deeb206923cb5388f60892366")
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
