// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import SwiftUI

/// L-45: desktop exposes progress in the heading; partial words stay on disk
/// for Stop/Resume but are not presented as a live desktop transcript.
struct MeetingTranscriptionStatus: View {
    @Bindable var model: MeetingDetailModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDetails = false
    private var meeting: LibraryMeeting { model.meeting }
    private var canStop: Bool {
        model.allowsTranscriptionChanges && !LibraryMoveCoordinator.shared.busy &&
        !TranscriptionQueue.shared.isStopping(meeting.folder)
    }
    private var status: String {
        guard let minutes = meeting.state.etaMinutes else { return UXText.text("states.badge.transcribing.noEta") }
        guard minutes > 0 else { return UXText.text("states.badge.transcribing.underMinute") }
        return UXText.text("transcribing.heading") + " · " + UXText.text("transcribing.eta.minutes", ["n": minutes.formatted(.number.locale(UXText.locale))])
    }
    private var timeLeft: String? {
        guard let minutes = meeting.state.etaMinutes else { return nil }
        guard minutes > 0 else { return UXText.text("states.badge.transcribing.underMinute") }
        return UXText.text("transcribing.stat.timeLeftValue", ["n": minutes.formatted(.number.locale(UXText.locale))])
    }
    private var speechModel: String? {
        let queue = TranscriptionQueue.shared
        let identifier = queue.active == meeting.folder ? queue.activeModel : meeting.transcriptModel
        switch identifier {
        case "whistle": return UXText.text("models.whistle.name")
        case let name? where name.hasPrefix("parakeet"): return UXText.text("models.parakeetUltra.name")
        default: return nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { statusButton; stopButton; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 10) { statusButton; stopButton }
            }
            // No denominator or trustworthy processed-duration signal is emitted
            // by the worker. Never infer a percentage from ETA or word timestamps.
            if reduceMotion {
                Capsule().fill(CassiniTheme.chipFill).frame(height: 3).accessibilityLabel(status)
            } else {
                ProgressView().progressViewStyle(.linear).tint(CassiniTheme.accent).frame(height: 3).accessibilityLabel(status)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("meeting-transcription-status")
    }
    private var statusButton: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 8) {
                if reduceMotion {
                    Image(systemName: "ellipsis.circle").foregroundStyle(CassiniTheme.accent).accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).tint(CassiniTheme.accent).accessibilityHidden(true)
                }
                Text(status).fontWeight(.semibold).accessibilityIdentifier("meeting-transcribing")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(CassiniTheme.ink2)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(status + ", " + UXText.text("transcribing.details.a11y"))
            .accessibilityIdentifier("meeting-transcription-details")
            .popover(isPresented: $showsDetails, arrowEdge: .top) { details }
    }
    private var stopButton: some View {
        Button(UXText.text("common.stop")) { stop() }
            .buttonStyle(.plain).fontWeight(.semibold).padding(.horizontal, 14).frame(height: 30)
            .background(CassiniTheme.chipFill, in: Capsule()).overlay(Capsule().stroke(CassiniTheme.tagStroke))
            .disabled(!canStop).accessibilityIdentifier("meeting-stop-transcription")
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(UXText.text("transcribing.heading")).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            // The engine does not publish stage transitions. List the work without
            // claiming a stage is current or completed.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["transcribing.step.reading", "transcribing.step.preparing", "transcribing.step.words", "transcribing.step.speakers", "transcribing.step.saving"], id: \.self) { step in
                    Text(UXText.text(step)).foregroundStyle(CassiniTheme.ink2)
                }
            }
            if speechModel != nil || timeLeft != nil {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    if let speechModel { metric(UXText.text("details.writing.model"), value: speechModel, id: "model") }
                    if let timeLeft { metric(UXText.text("transcribing.stat.timeLeft"), value: timeLeft, id: "time-left") }
                }
            }
            Button(UXText.text("transcribing.stopAndKeepProgress")) { stop() }
                .disabled(!canStop).accessibilityIdentifier("transcription-stop-keep-progress")
            Text(UXText.text("transcribing.backgroundNote")).font(.system(size: 11.5)).foregroundStyle(CassiniTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 320).foregroundStyle(CassiniTheme.ink).background(CassiniTheme.surface)
            .accessibilityElement(children: .contain).accessibilityIdentifier("transcription-popover")
    }
    private func metric(_ label: String, value: String, id: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(CassiniTheme.ink2)
            Text(value).monospacedDigit().accessibilityIdentifier("transcription-stat-" + id)
        }
    }
    private func stop() {
        guard canStop else { return }
        showsDetails = false
        TranscriptionQueue.shared.stop(meeting)
    }
}
