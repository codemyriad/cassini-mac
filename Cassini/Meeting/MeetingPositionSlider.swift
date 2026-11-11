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
        report["nativePointerClampsToTrack"] = slider.pointerPosition(at:-100,knobOffset:0) == 0 && slider.pointerPosition(at:1000,knobOffset:0) == 40000
        let grabbedX = CGFloat(slider.track.x(at:10000,duration:40000)) + 5
        report["nativePointerPreservesThumbGrabOffset"] = abs(slider.pointerPosition(at:grabbedX,knobOffset:5)-10000) < 0.001
        slider.beginTracking()
        slider.doubleValue = slider.pointerPosition(at:grabbedX,knobOffset:0)
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
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:360,height:120),
                              styleMask:.borderless,backing:.buffered,defer:false)
        defer { window.close() }
        let host = NSView(frame:NSRect(x:0,y:0,width:360,height:120))
        window.contentView = host
        slider.frame.origin = NSPoint(x:37,y:19)
        host.addSubview(slider)
        let editor = NSTextView(frame:NSRect(x:0,y:60,width:100,height:30))
        host.addSubview(editor); window.makeFirstResponder(editor)
        slider.testingAcceptsFirstResponder = true
        var values: [Double] = []
        coordinator.seek = { values.append($0) }
        func event(_ type:NSEvent.EventType,_ x:CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:slider.convert(NSPoint(x:x,y:slider.bounds.midY),to:nil),
                modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,
                eventNumber:0,clickCount:1,pressure:1)!
        }
        func drain() {
            while window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp],until:.distantPast,
                                   inMode:.eventTracking,dequeue:true) != nil {}
        }
        func pointer(_ down:CGFloat,_ drag:CGFloat? = nil,_ up:CGFloat) {
            values = []
            if let drag { window.postEvent(event(.leftMouseDragged,drag),atStart:false) }
            window.postEvent(event(.leftMouseUp,up),atStart:false)
            slider.mouseDown(with:event(.leftMouseDown,down))
            drain()
        }
        let initialPosition = 10001.25
        slider.doubleValue = initialPosition
        let center = cell.knobRect(flipped:slider.isFlipped).midX
        pointer(center+5,nil,center+5)
        report["nativeMouseDownPreservesOffCenterGrab"] = values.count == 1 && slider.doubleValue == initialPosition
        report["nativePointerKeepsTranscriptFocus"] = window.firstResponder === editor
        report["nativeMouseUpDoesNotRepeatSeek"] = values.count == 1
        var exactGrabs = true
        for width in [CGFloat(171),240,691] {
            slider.frame.size.width = width
            for value in [10001.25,18800,40000.0/3] {
                slider.doubleValue = value
                let x = cell.knobRect(flipped:slider.isFlipped).midX+5
                pointer(x,nil,x)
                exactGrabs = exactGrabs && values.count == 1 && slider.doubleValue == value
            }
        }
        report["nativeThumbGrabPreservesExactValues"] = exactGrabs
        slider.frame.size.width = 240; slider.doubleValue = initialPosition
        pointer(center+5,center+25,center+25)
        let expected = initialPosition + 20/slider.track.width*slider.maxValue
        report["nativeMouseDragUsesWindowCoordinates"] = values.count == 2 && abs(slider.doubleValue-expected) < 0.001
        pointer(-100,nil,-100)
        let atStart = slider.doubleValue == 0
        pointer(1000,nil,1000)
        report["nativeMouseDownClampsBothEnds"] = atStart && slider.doubleValue == 40000
        coordinator.timeline = timeline
        let near = CGFloat(slider.track.x(at:10000,duration:40000)) + 5
        pointer(near,nil,near)
        report["nativeMouseDownSnapsNearTurn"] = values.count == 1 && slider.doubleValue == 10000
        coordinator.timeline = ListeningTimeline()
        slider.isEnabled = false
        pointer(center+5,nil,center+5)
        report["nativeDisabledPointerIsIgnored"] = values.isEmpty && !slider.mouseTracking && dragged == nil
        slider.isEnabled = true
        slider.doubleValue = 10000
        coordinator.seek = { values.append($0); slider.isEnabled = false }
        pointer(center+5,center+25,center+25)
        report["nativeMouseDragStopsWhenDisabled"] = values.count == 1 && !slider.mouseTracking && dragged == nil
        slider.isEnabled = true; slider.doubleValue = 10000
        coordinator.seek = { values.append($0); slider.removeFromSuperview() }
        pointer(center+5,center+25,center+25)
        report["nativeMouseDragStopsWhenDetached"] = values.count == 1 && slider.window == nil && !slider.mouseTracking
        coordinator.seek = { _ in }
        return report
    }
    #endif
    static func readoutSpeaker(at value: Double, readout: TimelineReadout, names: [String:String]) -> String? {
        readout.speaker(at:value).map { names[$0] ?? UXText.text("common.speaker.unnamed",["n":"1"]) }
    }
    private func readoutLabel(_ value: Double, available: Double) -> some View {
        let time = LibraryFormat.position(Int64(value))
        let name = Self.readoutSpeaker(at:value,readout:readout,names:names)
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
        #if DEBUG
        var testingAcceptsFirstResponder: Bool?
        override var acceptsFirstResponder: Bool { testingAcceptsFirstResponder ?? super.acceptsFirstResponder }
        #endif
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
            defer { endTracking() }
            guard let window, let cell = cell as? NSSliderCell else { return }
            let knob = cell.knobRect(flipped:isFlipped)
            let point = convert(event.locationInWindow,from:nil)
            // Drag from the original numeric value. Inverse-mapping even the
            // ideal thumb center can round just below a displayed whole second.
            let grabbed = NSMouseInRect(point,knob,isFlipped)
            let initialPosition = doubleValue
            // macOS27's click animation can restore its unsnapped destination
            // after the action has snapped the value. Track pointer events with
            // public APIs; keyboard and accessibility still use NSSlider.
            var next: NSEvent? = event
            var lastX: CGFloat?
            while let current = next {
                guard isEnabled, self.window === window else { break }
                let x = convert(current.locationInWindow,from:nil).x
                if current.type != .leftMouseUp || x != lastX {
                    lastX = x
                    if grabbed, track.width > 0 {
                        doubleValue = min(maxValue,max(minValue,initialPosition + Double(x-point.x)/track.width*(maxValue-minValue)))
                    } else {
                        doubleValue = pointerPosition(at:x,knobOffset:0)
                    }
                    sendAction(action,to:target)
                }
                if current.type == .leftMouseUp || !isEnabled || self.window !== window { break }
                next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp],
                                        until:.distantFuture,inMode:.eventTracking,dequeue:true)
            }
        }
        func pointerPosition(at x: CGFloat, knobOffset: CGFloat) -> Double {
            track.position(at:Double(x-knobOffset),duration:maxValue)
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
