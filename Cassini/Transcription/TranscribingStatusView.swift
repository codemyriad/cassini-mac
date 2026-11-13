// SPDX-License-Identifier: GPL-3.0-or-later
import CassiniLibrary
import SwiftUI
import IOKit.ps

/// Status belongs to the meeting pane; the Library keeps its compact row badge.
struct TranscribingStatusView: View {
    let meeting: LibraryMeeting
    @State private var showingDetails = false
    @State private var queue = TranscriptionQueue.shared
    @State private var move = LibraryMoveCoordinator.shared
    @State private var batteryPercentAtFinish: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: TranscribingPresentation {
        .init(state:meeting.state, readOnly:meeting.metadataReadOnly,
              wordCount:meeting.transcriptItems.count, durationMs:meeting.durationMs,
              batteryPercentAtFinish:batteryPercentAtFinish,
              language:UXText.language, locale:UXText.locale)
    }
    private var stopDisabled: Bool {
        !presentation.canStop || move.busy || queue.isStopping(meeting.folder)
    }
    private func stop() {
        showingDetails = false
        queue.stop(meeting)
    }
    var body: some View {
        VStack(alignment:.leading, spacing:10) {
            HStack(spacing:10) {
                if reduceMotion {
                    Image(systemName:"hourglass").foregroundStyle(CassiniTheme.accent)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).tint(CassiniTheme.accent)
                        .accessibilityHidden(true)
                }
                Text(presentation.status).monospacedDigit().foregroundStyle(CassiniTheme.ink2)
                    .accessibilityIdentifier("transcribing-status")
                Spacer(minLength:8)
                if presentation.canStop {
                    Button(UXText.text("common.stop"), action:stop)
                        .buttonStyle(.plain).fontWeight(.semibold)
                        .padding(.horizontal,12).padding(.vertical,5)
                        .background(CassiniTheme.chipFill,in:Capsule())
                        .disabled(stopDisabled).accessibilityIdentifier("meeting-stop-transcription")
                }
                Button { showingDetails.toggle() } label: {
                    Image(systemName:"chevron.down").frame(width:28,height:28)
                }.buttonStyle(.plain)
                    .accessibilityLabel(UXText.text("transcribing.details.a11y"))
                    .accessibilityIdentifier("transcribing-details")
                    .popover(isPresented:$showingDetails, arrowEdge:.bottom) { details }
            }
            // The workers do not expose a processed-audio fraction. An indeterminate
            // bar avoids inventing a percentage from ETA or the last spoken word.
            if reduceMotion {
                Capsule().fill(CassiniTheme.chipFill).frame(height:3).accessibilityHidden(true)
            } else {
                ProgressView().progressViewStyle(.linear).tint(CassiniTheme.accent)
                    .frame(height:3).accessibilityLabel(presentation.status)
            }
        }.padding(.horizontal,28).padding(.vertical,14)
            .font(.system(size:13)).foregroundStyle(CassiniTheme.ink)
            .accessibilityElement(children:.contain).accessibilityIdentifier("transcribing-controls")
            .onChange(of:meeting.libraryKey) { _,_ in showingDetails = false }
            .task(id:meeting.state.etaMinutes) {
                batteryPercentAtFinish = nil
                let eta = meeting.state.etaMinutes
                let estimate = await Task.detached { TranscribingBattery.estimate(etaMinutes:eta) }.value
                guard !Task.isCancelled else { return }
                batteryPercentAtFinish = estimate
            }
    }
    private var details: some View {
        VStack(alignment:.leading, spacing:18) {
            Text(UXText.text("transcribing.heading")).font(.headline).accessibilityAddTraits(.isHeader)
            Grid(alignment:.leading, horizontalSpacing:24, verticalSpacing:14) {
                GridRow {
                    metric("transcribing.stat.audioDone",value:presentation.audioDone)
                    metric("transcribing.stat.timeLeft",value:presentation.timeLeft)
                }
                GridRow {
                    metric("transcribing.stat.wordsSoFar",value:presentation.wordsSoFar)
                    metric("transcribing.stat.batteryAtFinish",value:presentation.batteryAtFinish)
                }
            }
            Divider()
            // No stage is checked off without engine evidence. These are the
            // shared pipeline labels, rather than a simulated sequence of timers.
            ForEach(TranscribingPresentation.steps,id:\.self) { step in
                HStack(spacing:8) {
                    Image(systemName:"circle").font(.system(size:9)).accessibilityHidden(true)
                    Text(UXText.text(step))
                }.foregroundStyle(CassiniTheme.ink2)
            }
            if presentation.canStop {
                Button(UXText.text("transcribing.stopAndKeepProgress"),action:stop)
                    .buttonStyle(.plain).fontWeight(.semibold)
                    .padding(.horizontal,12).padding(.vertical,8)
                    .background(CassiniTheme.chipFill,in:Capsule())
                    .disabled(stopDisabled).accessibilityIdentifier("transcribing-stop-keep-progress")
            }
            Text(UXText.text("transcribing.backgroundNote"))
                .font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
                .fixedSize(horizontal:false,vertical:true)
        }.padding(20).frame(width:340).font(.system(size:13))
            .foregroundStyle(CassiniTheme.ink).background(CassiniTheme.paneGround)
            .accessibilityElement(children:.contain)
            .accessibilityLabel(UXText.text("transcribing.details.a11y"))
            .accessibilityIdentifier("transcribing-details-popover")
    }
    private func metric(_ id: String, value: String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(UXText.text(id)).font(.system(size:11.5)).foregroundStyle(CassiniTheme.ink2)
            Text(value).monospacedDigit().fontWeight(.semibold)
        }.accessibilityElement(children:.combine).accessibilityIdentifier(id)
    }
}

private enum TranscribingBattery {
    /// System power-source queries run off the UI actor. Only a discharging
    /// internal battery with a valid system runtime estimate supports projection.
    static func estimate(etaMinutes: Int64?) -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let remaining = IOPSGetTimeRemainingEstimate()
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info,source)?.takeUnretainedValue() as? [String:Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let charge = description[kIOPSCurrentCapacityKey] as? Double,
                  let capacity = description[kIOPSMaxCapacityKey] as? Double, capacity > 0 else { continue }
            return TranscribingPresentation.batteryAtFinish(etaMinutes:etaMinutes,
                chargePercent:100 * charge / capacity,secondsRemaining:remaining)
        }
        return nil
    }
}
