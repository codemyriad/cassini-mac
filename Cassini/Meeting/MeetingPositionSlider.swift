// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import CassiniLibrary

/// Native keyboard/VoiceOver behavior, with an immediate time/name readout and
/// independent Canvas marks. Listening never replaces ordinary seek semantics.
struct MeetingPositionSlider: View {
    @Binding var position: Double
    let duration: Double
    let readout: TimelineReadout
    let names: [String:String]
    let timeline: ListeningTimeline
    @State private var track = ListeningTimeline.Track(minX:12,width:0)
    @State private var hoverX: Double?
    @State private var draggedPosition: Double?

    var body: some View {
        GeometryReader { geometry in
            NativeMeetingSlider(position:$position,duration:duration,timeline:timeline,
                                geometryChanged:{ track = $0 },trackingChanged:{ draggedPosition = $0 })
                .overlay {
                    ListeningTicks(timeline:timeline,duration:duration,track:track).equatable()
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverX = point.x
                    case .ended: hoverX = nil
                    }
                }
                .overlay(alignment:.topLeading) {
                    if let value = draggedPosition ?? hoverX.map({ track.position(at:$0,duration:duration) }) {
                        readoutLabel(value,available:geometry.size.width)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }
    }

    #if DEBUG
    /// Same native action and tracking paths as pointer/VoiceOver interaction,
    /// without automation, an audio device, or a real meeting/library.
    static func nativeSelfTest() -> [String:Bool] {
        let words: [LibraryTranscriptItem] = [.init(speaker:"ada",startMs:10000,endMs:10300,text:"Agreed.")]
        let timeline = ListeningTimeline(turns:SpeakerTurn.grouping(words))
        let slider = NativeMeetingSlider.TimeSlider()
        slider.frame = NSRect(x:0,y:0,width:240,height:22)
        slider.minValue = 0; slider.maxValue = 40000
        var sought: Double = -1, dragged: Double?
        let coordinator = NativeMeetingSlider.Coordinator { sought = $0 }
        coordinator.timeline = timeline
        slider.target = coordinator; slider.action = #selector(NativeMeetingSlider.Coordinator.changed(_:))
        slider.trackingChanged = { dragged = $0 }
        let cell = slider.cell as! NSSliderCell
        slider.doubleValue = 0
        let left = cell.knobRect(flipped:slider.isFlipped).midX
        slider.doubleValue = 40000
        let right = cell.knobRect(flipped:slider.isFlipped).midX
        var report = ["nativeTrackMatchesThumbTravel": abs(slider.track.minX-left) < 0.001 && abs(slider.track.minX+slider.track.width-right) < 0.001]
        slider.beginTracking()
        slider.doubleValue = slider.track.position(at:slider.track.x(at:10000,duration:40000)+5,duration:40000)
        slider.sendAction(slider.action,to:slider.target)
        report["nativePointerSnapAndDragReadout"] = sought == 10000 && dragged == 10000 && slider.doubleValue == 10000
        slider.endTracking()
        report["nativeDragReadoutClears"] = dragged == nil
        slider.setAccessibilityValue(NSNumber(value:9900))
        report["nativeAccessibilitySeekDoesNotSnap"] = sought == 9900 && slider.accessibilityValue() as? String == "00:00:09"
        _ = slider.accessibilityPerformIncrement()
        report["nativeAccessibilityTenSecondStep"] = sought == 19900
        coordinator.timeline = ListeningTimeline()
        slider.beginTracking(); slider.doubleValue = 9900
        slider.sendAction(slider.action,to:slider.target); slider.endTracking()
        report["nativeStopClearsSnap"] = sought == 9900
        return report
    }
    #endif
    private func readoutLabel(_ value: Double, available: Double) -> some View {
        let time = LibraryFormat.position(Int64(value))
        let name = readout.speaker(at:value).flatMap { names[$0] }
        let label = name.map { UXText.text("player.timeline.tooltip",["position":time,"name":$0]) } ?? time
        let width = min(280,available)
        let x = track.x(at:value,duration:duration)
        return Text(label).font(.system(size:11.5)).monospacedDigit().lineLimit(1)
            .padding(.horizontal,8).padding(.vertical,5)
            .frame(width:width).background(.regularMaterial,in:RoundedRectangle(cornerRadius:5))
            .overlay(RoundedRectangle(cornerRadius:5).stroke(.primary.opacity(0.2)))
            .offset(x:min(max(0,x-width/2),max(0,available-width)),y:-30)
            .accessibilityIdentifier("meeting-seek-readout")
    }
}

/// No playback position input: a clock update cannot invalidate this Canvas.
private struct ListeningTicks: View, Equatable {
    let timeline: ListeningTimeline
    let duration: Double
    let track: ListeningTimeline.Track
    var body: some View {
        Canvas { context,size in
            for x in timeline.marks(duration:duration,track:track) {
                let mark = CGRect(x:CGFloat(x)-1.5,y:size.height/2-4,width:3,height:8)
                context.fill(Path(roundedRect:mark,cornerRadius:1),with:.color(.accentColor))
            }
        }
    }
}

/// NSSlider permits a string accessibility value. Keep its numeric thumb model
/// while exposing time (SwiftUI's value modifier leaves the millisecond number).
private struct NativeMeetingSlider: NSViewRepresentable {
    @Binding var position: Double
    let duration: Double
    let timeline: ListeningTimeline
    let geometryChanged: (ListeningTimeline.Track) -> Void
    let trackingChanged: (Double?) -> Void
    @Environment(\.isEnabled) private var isEnabled
    final class Coordinator: NSObject {
        var seek: (Double) -> Void
        var timeline = ListeningTimeline()
        init(seek: @escaping (Double) -> Void) { self.seek = seek }
        @objc func changed(_ sender: TimeSlider) {
            if sender.mouseTracking {
                sender.doubleValue = timeline.snapped(sender.doubleValue,duration:sender.maxValue,track:sender.track)
                sender.trackingChanged?(sender.doubleValue)
            }
            seek(sender.doubleValue)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator { position = $0 } }
    func makeNSView(context: Context) -> TimeSlider {
        let slider = TimeSlider()
        slider.isContinuous = true; slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityIdentifier("meeting-seek")
        slider.setAccessibilityLabel(UXText.text("player.position"))
        return slider
    }
    func updateNSView(_ slider: TimeSlider, context: Context) {
        context.coordinator.seek = { position = $0 }; context.coordinator.timeline = timeline
        slider.geometryChanged = geometryChanged; slider.trackingChanged = trackingChanged
        slider.minValue = 0; slider.maxValue = duration
        if !slider.mouseTracking { slider.doubleValue = min(duration,max(0,position)) }
        slider.isEnabled = isEnabled
    }
    final class TimeSlider: NSSlider {
        var geometryChanged: ((ListeningTimeline.Track) -> Void)?
        var trackingChanged: ((Double?) -> Void)?
        private(set) var mouseTracking = false
        private var lastTrack: ListeningTimeline.Track?
        var track: ListeningTimeline.Track {
            let inset = (cell as? NSSliderCell)?.knobRect(flipped:isFlipped).width ?? 24
            return .init(minX:inset/2,width:max(0,bounds.width-inset))
        }
        override func layout() {
            super.layout()
            let current = track
            guard current != lastTrack else { return }
            lastTrack = current
            // Layout/updateNSView must finish before changing SwiftUI state.
            Task { @MainActor [weak self] in
                guard let self, self.track == current else { return }
                self.geometryChanged?(current)
            }
        }
        func beginTracking() { mouseTracking = true; trackingChanged?(doubleValue) }
        func endTracking() { mouseTracking = false; trackingChanged?(nil) }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            beginTracking()
            super.mouseDown(with:event)
            endTracking()
        }
        override func accessibilityValue() -> Any? { LibraryFormat.position(Int64(doubleValue)) }
        override func accessibilityValueDescription() -> String? { LibraryFormat.position(Int64(doubleValue)) }
        override func setAccessibilityValue(_ value: Any?) {
            if let number = value as? NSNumber { _ = apply(number.doubleValue) }
            else if let text = value as? String {
                let fields = text.split(separator:":",omittingEmptySubsequences:false)
                let parts = fields.compactMap { Double($0) }
                if fields.count == 3, parts.count == 3, parts[0] >= 0, (0..<60).contains(parts[1]), (0..<60).contains(parts[2]) {
                    _ = apply(parts[0]*3600000 + parts[1]*60000 + parts[2]*1000)
                }
            }
        }
        override func accessibilityPerformIncrement() -> Bool { apply(doubleValue + 10000) }
        override func accessibilityPerformDecrement() -> Bool { apply(doubleValue - 10000) }
        private func apply(_ value: Double) -> Bool {
            guard isEnabled, value.isFinite else { return false }
            let position = min(maxValue,max(minValue,value))
            guard position != doubleValue else { return false }
            doubleValue = position; sendAction(action,to:target)
            return true
        }
    }
}
