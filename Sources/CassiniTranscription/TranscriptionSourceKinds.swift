// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Shared source-kind selection retained for the future D46 PCM stage.
/// These sets have no effect on transcription until that stage is specified.
public enum TranscriptionSourceKinds {
    public static let microphones: Set<String> = ["microphone", "local"]
    public static let references: Set<String> = ["system", "application", "remote", "media", "tab"]
}
