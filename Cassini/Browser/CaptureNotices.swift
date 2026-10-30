// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniBrowserControl
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
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            Text(UXText.text(side == .me ? (CaptureSettings.microphoneAllowed ? "errors.micSilentRow.line" : "errors.micPermission.line") : "errors.othersPermission.line")).fixedSize(horizontal:false,vertical:true)
            Button(UXText.text(side == .me ? (CaptureSettings.microphoneAllowed ? "errors.micSilentRow.action" : "errors.micPermission.action") : "errors.othersPermission.action")) {
                if side == .me && CaptureSettings.microphoneAllowed {
                    CaptureCollection.shared.settingsWereOpened(.me)
                    NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!)
                } else { CaptureSettings.open(side) }
            }
        }.font(.system(size:11.5)).foregroundStyle(LibraryTheme.dim)
            .accessibilityIdentifier(side == .me ? "capture-microphone-permission" : "capture-others-permission")
    }
}
struct CaptureFailureBanner: View {
    @State private var captures = CaptureCollection.shared
    var body: some View {
        if captures.diskStopped || captures.recordFailed || !captures.failedMeetings.isEmpty { VStack(spacing:0) {
            if captures.diskStopped {
                Text(UXText.text("errors.diskStopped.line")).font(.system(size:13)).padding(.horizontal,18).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading).background(LibraryTheme.amberTint)
            }
            if captures.recordFailed {
                line(UXText.text("errors.recordFailed.line")) { Task { try? await captures.record() } }
            } else {
                ForEach(captures.failedMeetings.keys.sorted(by:{ $0.peer.uuidString == $1.peer.uuidString ? $0.tabID < $1.tabID : $0.peer.uuidString < $1.peer.uuidString }),id:\.self) { key in
                    line(UXText.text("errors.recordFailed.meeting",["title":captures.failedMeetings[key] ?? UXText.text("library.untitled")])) { captures.retry(key) }
                }
            }
        }.accessibilityElement(children:.contain).accessibilityIdentifier("capture-failure-banner") }
    }
    private func line(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing:12) {
            Text(message).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:8)
            Button(UXText.text("common.tryAgain"),action:retry).disabled(captures.starting)
        }.font(.system(size:13)).padding(.horizontal,18).padding(.vertical,10).background(LibraryTheme.amberTint)
    }
}
