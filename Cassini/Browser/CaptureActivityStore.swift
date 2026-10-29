// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniLibrary

/// Factories announce a UUID before creating its folder. The scanner sees
/// preparation without waiting for UI callbacks or reading partial metadata.
/// This process-local producer state is never persisted as provenance.
final class CaptureActivityStore: CaptureActivityProviding, @unchecked Sendable {
    static let shared = CaptureActivityStore()
    private let lock = NSLock()
    private var phases: [UUID:CaptureActivity] = [:]
    func set(_ id: UUID, _ phase: CaptureActivity?) { lock.withLock { phases[id] = phase } }
    func snapshot() -> [UUID:CaptureActivity] { lock.withLock { phases } }
}
