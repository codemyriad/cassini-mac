// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniBrowserControl
import CassiniRecording
import AVFoundation

@MainActor enum CaptureSettings {
    static var microphoneAllowed: Bool {
        #if DEBUG
        if CaptureFixture.enabled { return CaptureFixture.microphoneAllowed }
        #endif
        return AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
    }
    static func open(_ side: CaptureSide) {
        CaptureCollection.shared.settingsWereOpened(side)
        let anchor = side == .me ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?" + anchor)!)
    }
}
struct CapturePermissionNotice: View {
    let side: CaptureSide
    /// D58: the side's refusal code, when it never opened.
    var refusal: String? = nil
    var body: some View {
        if side == .others, refusal != CaptureRefusal.permissionDenied {
            // D58.1: the system tap could not be started; no settings action applies.
            Text(UXText.text("errors.deviceUnavailable.others")).fixedSize(horizontal:false,vertical:true)
                .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).accessibilityIdentifier("capture-others-unavailable")
        } else if side == .me, refusal == "deviceUnavailable" {
            // The microphone could not be started at all; no settings action applies.
            Text(UXText.text("errors.deviceUnavailable.me")).fixedSize(horizontal:false,vertical:true)
                .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2).accessibilityIdentifier("capture-microphone-unavailable")
        } else { permission }
    }
    private var permission: some View {
        HStack(alignment:.top,spacing:10) {
            Text(UXText.text(side == .me ? (CaptureSettings.microphoneAllowed ? "errors.micSilentRow.line" : "errors.micPermission.line") : "errors.othersPermission.line")).fixedSize(horizontal:false,vertical:true)
            Button(UXText.text(side == .me ? (CaptureSettings.microphoneAllowed ? "errors.micSilentRow.action" : "errors.micPermission.action") : "errors.othersPermission.action")) {
                if side == .me && CaptureSettings.microphoneAllowed {
                    CaptureCollection.shared.settingsWereOpened(.me)
                    NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!)
                } else { CaptureSettings.open(side) }
            }
            .buttonStyle(PageSecondaryButtonStyle())
            .controlSize(.small)
        }.font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
            .accessibilityIdentifier(side == .me ? "capture-microphone-permission" : "capture-others-permission")
    }
}
struct CaptureFailureBanner: View {
    @State private var captures = CaptureCollection.shared
    var body: some View {
        if captures.hasFailure {
            VStack(alignment: .leading, spacing: 8) {
                if captures.diskStopped {
                    line(UXText.text("errors.diskStopped.line"), retry: nil, dismiss: { captures.dismissDiskStopped() })
                }
                if captures.recordFailed {
                    line(
                        UXText.text("errors.recordFailed.line"),
                        captions: captures.attemptRefusals,
                        retry: { Task { try? await captures.record() } },
                        dismiss: { captures.dismissRecordFailure() }
                    )
                } else {
                    ForEach(captures.failedMeetings.keys.sorted(by: { $0.peer.uuidString == $1.peer.uuidString ? $0.tabID < $1.tabID : $0.peer.uuidString < $1.peer.uuidString }), id: \.self) { key in
                        line(
                            UXText.text("errors.recordFailed.meeting", ["title": captures.failedMeetings[key] ?? UXText.text("library.untitled")]),
                            captions: captures.meetingRefusals[key].map { [$0] } ?? [],
                            retry: { captures.retry(key) },
                            dismiss: { captures.dismissFailedMeeting(key) }
                        )
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture-failure-banner")
        }
    }
    /// D58 captions: busy, noSources, and no answer (startFailed timeout or disconnected).
    static func caption(_ refusal: CaptureRefusal) -> String? {
        switch (refusal.code, refusal.detail) {
        case (_, "busy"?): return "errors.refusal.busy"
        case (_, "noSources"?): return "errors.refusal.noSources"
        case (CaptureRefusal.startFailed, "timeout"?), (CaptureRefusal.startFailed, "disconnected"?): return "errors.refusal.noAnswer"
        default: return nil
        }
    }
    private func line(_ message: String, captions refusals: [CaptureRefusal] = [], retry: (() -> Void)?, dismiss: @escaping () -> Void) -> some View {
        let captions = refusals.compactMap(Self.caption).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(captions, id: \.self) {
                    Text(UXText.text($0))
                        .font(.system(size: 11.5))
                        .foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button(UXText.text("common.tryAgain"), action: retry)
                    .buttonStyle(PageSecondaryButtonStyle())
                    .disabled(captures.starting)
                    .accessibilityIdentifier("capture-failure-retry")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(UXText.text("common.close"))
            .accessibilityLabel(UXText.text("common.close"))
            .accessibilityIdentifier("capture-failure-close")
        }
        .font(.system(size: 13))
        .padding(12)
        .foregroundStyle(CassiniTheme.inlineWarnInk)
        .background(CassiniTheme.inlineWarnTint, in: RoundedRectangle(cornerRadius: 7))
    }
}
