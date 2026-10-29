// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// An aggregate for global controls; each Recording page still addresses only
/// its own owner. The older controller is retained for existing private fixtures.
@MainActor enum RecordingOverview {
    static var active: Bool { RecordingController.shared.isRecording || CaptureCollection.shared.isRecording }
    static var starting: Bool { RecordingController.shared.isStarting || CaptureCollection.shared.starting }
    static var saving: Bool { RecordingController.shared.isSaving || CaptureCollection.shared.isSaving }
    static var canStart: Bool { !active && !starting && !saving && RecordingController.shared.canStart }
    static var elapsedMs: Int64 {
        max(RecordingController.shared.isRecording ? RecordingController.shared.elapsedMs : 0,CaptureCollection.shared.first?.elapsedMs ?? 0)
    }
    static var startedAt: Date? {
        let native = RecordingController.shared.isRecording ? RecordingController.shared.startedAt : nil
        let browser = CaptureCollection.shared.first.map { Date().addingTimeInterval(-Double($0.elapsedMs)/1000) }
        return [native,browser].compactMap { $0 }.min()
    }
    static var directory: URL? {
        let native = RecordingController.shared
        if native.isRecording, native.elapsedMs >= (CaptureCollection.shared.first?.elapsedMs ?? 0) { return native.directory }
        return CaptureCollection.shared.first?.snapshot.directory ?? native.directory
    }
    static var title: String {
        if let browser = CaptureCollection.shared.first, !RecordingController.shared.isRecording || browser.elapsedMs > RecordingController.shared.elapsedMs { return browser.displayTitle ?? browser.snapshot.manifest.title }
        return RecordingController.shared.title
    }
    static var levels: [String:Float] {
        if let first = CaptureCollection.shared.first, !RecordingController.shared.isRecording || first.elapsedMs > RecordingController.shared.elapsedMs {
            return ["microphone":first.levels[.me,default:0],"output":first.levels[.others,default:0]]
        }
        return RecordingController.shared.levels
    }
    static var diskLine: String? {
        if CaptureCollection.shared.diskStopped { return UXText.text("errors.diskStopped.line") }
        if !CaptureCollection.shared.captures.isEmpty {
            return CaptureCollection.shared.captures.values.compactMap(\.diskMinutes).min().map { UXText.text("errors.diskLow.line",["n":String($0)]) }
        }
        return RecordingController.shared.diskLine
    }
    static func stop() { RecordingController.shared.stop(); CaptureCollection.shared.stopAll() }
    static func stopAndWait() async {
        stop(); await RecordingController.shared.finishTask?.value
        await CaptureCollection.shared.stopAndWait()
    }
}
