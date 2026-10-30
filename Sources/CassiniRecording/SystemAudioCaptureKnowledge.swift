// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation

/// Prior successful input knowledge, never an OS permission preflight. Only a
/// real system-input attempt may supply evidence. Metadata writes stay off IO.
public final class SystemAudioCaptureKnowledge: @unchecked Sendable {
    public static let shared = SystemAudioCaptureKnowledge(defaults: .standard)
    private static let key = "CassiniVerifiedSystemAudioCapture"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let persistence = DispatchQueue(label: "io.codemyriad.cassini.system-audio-knowledge", qos: .utility)
    private var epoch: UInt64 = 0
    private var verified: Bool

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        verified = defaults.bool(forKey: Self.key)
    }
    public var previouslyCaptured: Bool {
        lock.lock(); defer { lock.unlock() }; return verified
    }
    public func beginAttempt() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return epoch
    }
    /// Returns true only for finite nonzero samples delivered by this input.
    /// Silence, invalid samples and merely starting a tap provide no evidence.
    public func receive(_ buffer: AVAudioPCMBuffer, attempt: UInt64) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            for frame in 0..<count {
                let sample = buffer.format.isInterleaved ? channels[0][frame*channelCount+channel] : channels[channel][frame]
                if sample.isFinite, sample != 0 { receivedNonzero(attempt:attempt); return true }
            }
        }
        return false
    }
    func receivedNonzero(attempt: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard attempt == epoch, !verified else { return }
        verified = true
        persistence.async { [self] in defaults.set(true, forKey: Self.key) }
    }
    public func failedStart() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        verified = false
        persistence.async { [self] in defaults.set(false, forKey: Self.key) }
    }
    /// Drain only from a non-IO context, e.g. before independently reading the
    /// persisted state. No capture, hardware access or permission request occurs.
    public func flush() { persistence.sync {} }
}
