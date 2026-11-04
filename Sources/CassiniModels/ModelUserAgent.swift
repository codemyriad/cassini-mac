// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D54: every model request names the app and its marketing version, plus the platform:
/// `CassiniTalk/<version> (macOS <major.minor[.patch]>; <arch>)`. Nothing that identifies a
/// person or a device. Built once in the app layer and passed to `ModelDownloader`.
public enum ModelUserAgent {
    public static func make(version: String, system: OperatingSystemVersion, architecture: String) -> String {
        let os = "\(system.majorVersion).\(system.minorVersion)" + (system.patchVersion > 0 ? ".\(system.patchVersion)" : "")
        return "CassiniTalk/\(token(version)) (macOS \(os); \(token(architecture)))"
    }
    /// The running app: its bundle's CFBundleShortVersionString, this macOS and this binary's architecture.
    public static func app(bundle: Bundle = .main) -> String {
        make(version:bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "",
             system:ProcessInfo.processInfo.operatingSystemVersion,architecture:architecture)
    }
    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
    /// A header-safe token; never a stale literal in place of a missing version.
    static func token(_ value: String) -> String {
        let safe = !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43,45,46,95].contains($0) }
        return safe ? value : "unknown"
    }
}
