// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuartzCore
import IOSurface
import SwiftUI
import CassiniRecording
import CassiniKit
import CassiniSpectrogram

/// One display clock and surface pair per capture. The Library pill and both
/// page rows consume the same batch, avoiding competing drains or repeated FFTs.
@MainActor final class RecordingSpectrogram: NSObject {
    static let enabled = ProcessInfo.processInfo.environment["CASSINI_SPECTRO"] != "0"
    let engine: SpectrogramSession
    let originUptime: TimeInterval
    private let observers: RecordedPCMObservers?
    private struct Selection { let at: Double, me: Bool, others: Bool }
    private struct WeakView { weak var value: RecordingSpectrogramView? }
    @MainActor private final class LinkTarget: NSObject {
        weak var owner: RecordingSpectrogram?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private struct Cleanup: @unchecked Sendable {
        let link: CADisplayLink?
        let timer: Timer?
        let notifications: [NSObjectProtocol]
    }
    private var views: [UUID:WeakView] = [:]
    private var selections: [Selection]
    private var eventCount = -1
    private let target = LinkTarget()
    private var link: CADisplayLink?
    private var reducedTimer: Timer?
    private var timerInterval: TimeInterval = 0
    private var pageRate: Bool?
    private weak var clockView: RecordingSpectrogramView?
    private var notifications: [NSObjectProtocol] = []
    private var generation = 0, inFlight = false, running = false, stopped = false
    private var pageBank: SpectrogramSurface?, pillBank: SpectrogramSurface?
    private var pageRevision = 0, pillRevision = 0
    private var mePage = SpectrogramPixelRing(style:.row,dark:false)
    private var othersPage = SpectrogramPixelRing(style:.row,dark:false)
    private var mePill = SpectrogramPixelRing(style:.pill,dark:false)
    private var othersPill = SpectrogramPixelRing(style:.pill,dark:false)
    private var lastPage: Int64 = -1, lastPill: Int64 = -1
    private var dark = false, silent = false, reduced = false
    private var appliedDark = false, appliedSilent = false, appliedReduced = false
    private var pageNeedsBake = true, pillNeedsBake = true
    private(set) var frameCallbacks: UInt64 = 0, framesApplied: UInt64 = 0
    private(set) var skippedFrames: UInt64 = 0, maxFrameIntervalMs = 0.0
    private(set) var analyzedFrames: UInt64 = 0, lateColumns: UInt64 = 0, droppedColumns: UInt64 = 0
    private var lastAppliedTime: Double?
    private var intervals = [UInt32](repeating:0,count:512)
    private var intervalCount: UInt64 = 0
    private var lastDisplayMs = 0.0

    init(originUptime: TimeInterval, observers: RecordedPCMObservers? = nil, me: Bool = true, others: Bool = true) {
        self.observers = observers
        self.originUptime = originUptime; engine = .init(originUptime:originUptime)
        selections = [.init(at:0,me:me,others:others)]
        super.init(); target.owner = self
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification,
            NSWindow.didChangeScreenNotification,NSWindow.didChangeBackingPropertiesNotification,
            NSApplication.didHideNotification,NSApplication.didUnhideNotification,
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification]
        notifications = names.map { name in
            NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.appearance(dark:self.dark,silent:self.silent); self.reconcile()
                }
            }
        }
    }
    deinit {
        engine.setVisible(false); observers?.set(nil)
        let cleanup = Cleanup(link:link,timer:reducedTimer,notifications:notifications)
        DispatchQueue.main.async {
            cleanup.link?.invalidate(); cleanup.timer?.invalidate()
            cleanup.notifications.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
    func update(events: [CaptureEvent]) {
        guard events.count != eventCount else { return }; eventCount = events.count
        let values = events.compactMap { event -> Selection? in
            guard event.type == "selection", let at = event.atMs, at.isFinite, at >= 0, let me = event.me, let others = event.others else { return nil }
            return .init(at:at,me:me,others:others)
        }
        if !values.isEmpty { selections = values }
    }
    func add(_ view: RecordingSpectrogramView) { views[view.registrationID] = .init(value:view); reconcile() }
    func remove(_ id: UUID) { views.removeValue(forKey:id); reconcile() }
    func appearance(dark: Bool, silent: Bool) {
        self.dark = dark; self.silent = silent
        let motion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if dark != appliedDark || silent != appliedSilent || motion != appliedReduced {
            reduced = motion; pageNeedsBake = true; pillNeedsBake = true
            appliedDark = dark; appliedSilent = silent; appliedReduced = motion
        }
    }
    func stop(atMs: Double) {
        guard !stopped else { return }; stopped = true; engine.stop(atMs:atMs)
        generation += 1; link?.invalidate(); link = nil; reducedTimer?.invalidate(); reducedTimer = nil; clockView = nil; inFlight = false
        engine.setVisible(false); observers?.set(nil)
        for view in views.values.compactMap(\.value) { view.freeze() }
    }
    func reconcile() {
        if views.values.contains(where:{ $0.value == nil }) { views = views.filter { $0.value.value != nil } }
        let visible = views.values.compactMap(\.value).filter(\.visibleForSpectrogram)
        let page = visible.contains { $0.style == .row }
        let primary: RecordingSpectrogramView?
        if let current = clockView, visible.contains(where:{ $0 === current }), !page || current.style == .row { primary = current }
        else { primary = visible.first(where:{ $0.style == .row }) ?? visible.first }
        guard Self.enabled, !stopped, let primary else {
            if running {
                generation += 1; running = false; inFlight = false; engine.setVisible(false); observers?.set(nil)
                link?.invalidate(); link = nil; reducedTimer?.invalidate(); reducedTimer = nil; clockView = nil; pageRate = nil
                pageBank = nil; pillBank = nil; lastPage = -1; lastPill = -1
                mePage = .init(style:.row,dark:dark); othersPage = .init(style:.row,dark:dark)
                mePill = .init(style:.pill,dark:dark); othersPill = .init(style:.pill,dark:dark)
                pageNeedsBake = true; pillNeedsBake = true
                for view in views.values.compactMap(\.value) { view.suspend() }
            }
            return
        }
        if !running { running = true; engine.setVisible(true); observers?.set(engine); lastAppliedTime = nil }
        if reduced {
            link?.invalidate(); link = nil; clockView = nil; pageRate = nil
            let interval: TimeInterval = page ? 0.02 : 0.08
            if reducedTimer == nil || timerInterval != interval {
                reducedTimer?.invalidate(); timerInterval = interval
                let timer = Timer(timeInterval:interval,repeats:true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reducedTick() }
                }
                RunLoop.main.add(timer,forMode:.common); reducedTimer = timer
            }
        } else {
            reducedTimer?.invalidate(); reducedTimer = nil
            if clockView !== primary || link == nil {
                link?.invalidate(); clockView = primary; pageRate = nil
                let value = primary.displayLink(target:target,selector:#selector(LinkTarget.tick(_:)))
                value.add(to:.main,forMode:.common); link = value
            }
            if let link, pageRate != page {
                link.preferredFrameRateRange = page ? .default : .init(minimum:30,maximum:30,preferred:30)
                pageRate = page
            }
        }
        if page, pageBank == nil { pageBank = try? .init(style:.row); pageNeedsBake = true }
        if visible.contains(where:{ $0.style == .pill }), pillBank == nil { pillBank = try? .init(style:.pill); pillNeedsBake = true }
    }
    private func selected(_ lane: SpectrogramLane, slot: Int64) -> Bool {
        let time = Double(slot)*20
        var lo = 0, hi = selections.count
        while lo < hi { let mid = (lo+hi)/2; if selections[mid].at <= time { lo = mid+1 } else { hi = mid } }
        let value = selections[max(0,lo-1)]
        return lane == .me ? value.me : value.others
    }
    private func tick(_ value: CADisplayLink) {
        guard value === link, running, !stopped else { return }
        reconcile(); guard running, !reduced else { return }
        frameCallbacks += 1; requestFrame(timestamp:value.targetTimestamp)
    }
    private func reducedTick() {
        guard running, !stopped, reduced else { return }
        reconcile(); guard running, reduced else { return }
        requestFrame(timestamp:CACurrentMediaTime())
    }
    private func requestFrame(timestamp: Double) {
        guard !inFlight else { skippedFrames += 1; return }; inFlight = true
        let revision = generation
        engine.requestFrame(nowMs:max(0,(timestamp-originUptime)*1000)) { [weak self] frame in
            DispatchQueue.main.async {
                guard let self, self.generation == revision, self.running, !self.stopped else { return }
                self.inFlight = false; self.analyzedFrames = frame.analyzedFrames
                self.lateColumns = frame.lateColumns; self.droppedColumns = frame.droppedColumns
                self.paint(me:frame.me,others:frame.others,displayMs:frame.displayMs)
                if let previous = self.lastAppliedTime {
                    let ms = (timestamp-previous)*1000
                    self.maxFrameIntervalMs = max(self.maxFrameIntervalMs,ms)
                    let bin = min(511,max(0,Int(ceil(ms*10))))
                    self.intervals[bin] &+= 1; self.intervalCount += 1
                }
                self.lastAppliedTime = timestamp; self.framesApplied += 1
            }
        }
    }
    private func paint(me: [SpectrogramColumn], others: [SpectrogramColumn], displayMs: Double) {
        lastDisplayMs = displayMs
        let pageEnd = Int64(floor(displayMs/20)), pillEnd = Int64(floor((displayMs-60)/80))
        if pageNeedsBake, let bank = pageBank {
            try? bank.withWritableColumns { writer in
                mePage.configure(dark:dark,silent:silent,reducedMotion:reduced) { writer.column(lane:.me,index:$0,pixels:$1) }
                othersPage.configure(dark:dark,silent:false,reducedMotion:reduced) { writer.column(lane:.others,index:$0,pixels:$1) }
            }; pageRevision += 1; pageNeedsBake = false
        }
        if pageEnd > lastPage {
            let first = max(0,max(lastPage+1,pageEnd-201))
            var m = 0, o = 0
            func remember(_ writer: SpectrogramSurface.Writer?) {
                if first <= pageEnd { for slot in first...pageEnd {
                    while m < me.count && me[m].slot < slot { m += 1 }
                    while o < others.count && others[o].slot < slot { o += 1 }
                    let a = m < me.count && me[m].slot == slot ? me[m].bands : nil
                    let b = o < others.count && others[o].slot == slot ? others[o].bands : nil
                    if let writer {
                        mePage.append(slot:slot,bands:a,recorded:selected(.me,slot:slot)) { writer.column(lane:.me,index:$0,pixels:$1) }
                        othersPage.append(slot:slot,bands:b,recorded:selected(.others,slot:slot)) { writer.column(lane:.others,index:$0,pixels:$1) }
                    } else {
                        mePage.remember(slot:slot,bands:a,recorded:selected(.me,slot:slot))
                        othersPage.remember(slot:slot,bands:b,recorded:selected(.others,slot:slot))
                    }
                } }
            }
            if let bank = pageBank { try? bank.withWritableColumns { remember($0) }; pageRevision += 1 }
            else { remember(nil) }
            lastPage = pageEnd
        }
        if pillNeedsBake, let bank = pillBank {
            try? bank.withWritableColumns { writer in
                mePill.configure(dark:dark,silent:silent,reducedMotion:reduced) { writer.column(lane:.me,index:$0,pixels:$1) }
                othersPill.configure(dark:dark,silent:false,reducedMotion:reduced) { writer.column(lane:.others,index:$0,pixels:$1) }
            }; pillRevision += 1; pillNeedsBake = false
        }
        if pillEnd > lastPill {
            let first = max(0,max(lastPill+1,pillEnd-51))
            func remember(_ writer: SpectrogramSurface.Writer?) {
                if first <= pillEnd { for slot in first...pillEnd {
                    let times = (0..<4).map { slot*4+Int64($0) }
                    let a = SpectrogramPillPooling.bands(times.map { mePage.bandValues(at:$0) })
                    let b = SpectrogramPillPooling.bands(times.map { othersPage.bandValues(at:$0) })
                    let m = times.contains { selected(.me,slot:$0) }, o = times.contains { selected(.others,slot:$0) }
                    if let writer {
                        mePill.append(slot:slot,bands:a,recorded:m) { writer.column(lane:.me,index:$0,pixels:$1) }
                        othersPill.append(slot:slot,bands:b,recorded:o) { writer.column(lane:.others,index:$0,pixels:$1) }
                    } else { mePill.remember(slot:slot,bands:a,recorded:m); othersPill.remember(slot:slot,bands:b,recorded:o) }
                } }
            }
            if let bank = pillBank { try? bank.withWritableColumns { remember($0) }; pillRevision += 1 }
            else { remember(nil) }
            lastPill = pillEnd
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for view in views.values.compactMap(\.value) where view.visibleForSpectrogram {
            let bank = view.style == .pill ? pillBank : pageBank
            if let bank { view.present(bank:bank,revision:view.style == .pill ? pillRevision : pageRevision,
                displayMs:view.style == .pill ? displayMs-60 : displayMs,reduced:reduced) }
        }
        CATransaction.commit()
    }
    var payloadBytes: Int {
        (pageBank?.allocatedBytes ?? 0)+(pillBank?.allocatedBytes ?? 0)+mePage.storageBytes+othersPage.storageBytes +
            mePill.storageBytes+othersPill.storageBytes+intervals.count*4+selections.count*MemoryLayout<Selection>.stride+64*37*2
    }
}

@MainActor final class RecordingSpectrogramView: NSView {
    let registrationID = UUID()
    let style: SpectrogramStripStyle
    let rowLane: SpectrogramLane
    private weak var controller: RecordingSpectrogram?
    private weak var bank: SpectrogramSurface?
    private var source: RecordingSurfaceContents?
    private var revision = -1
    private struct LaneLayers { let clip = CALayer(), first = CALayer(), second = CALayer(), fade = CAGradientLayer() }
    private var lanes: [LaneLayers] = []
    init(style: SpectrogramStripStyle, lane: SpectrogramLane = .me) {
        self.style = style; rowLane = lane; super.init(frame:.zero)
        wantsLayer = true; setAccessibilityElement(false)
        for _ in 0..<(style == .pill ? 2 : 1) {
            let item = LaneLayers(); item.clip.masksToBounds = true; item.clip.cornerRadius = 2
            for image in [item.first,item.second] {
                image.anchorPoint = .zero; image.contentsGravity = .resize
                image.minificationFilter = .linear; image.magnificationFilter = .linear
                item.clip.addSublayer(image)
            }
            item.fade.colors = [NSColor.clear.cgColor,NSColor.white.cgColor,NSColor.white.cgColor]
            item.fade.locations = [0,0.16,1]; item.fade.startPoint = .init(x:0,y:0.5); item.fade.endPoint = .init(x:1,y:0.5)
            layer?.addSublayer(item.clip); lanes.append(item)
        }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var visibleForSpectrogram: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) &&
            !NSApp.isHidden && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }
    func configure(_ value: RecordingSpectrogram?, dark: Bool, silent: Bool) {
        if controller !== value { controller?.remove(registrationID); suspend(); controller = value; value?.add(self) }
        value?.appearance(dark:dark,silent:silent)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller?.reconcile() }
    override func viewDidHide() { super.viewDidHide(); controller?.reconcile() }
    override func viewDidUnhide() { super.viewDidUnhide(); controller?.reconcile() }
    override func layout() { super.layout(); controller?.reconcile() }
    func detach() { controller?.remove(registrationID); controller = nil; suspend() }
    func suspend() {
        for lane in lanes {
            lane.first.contents = nil; lane.second.contents = nil
            lane.first.delegate = nil; lane.second.delegate = nil
        }; bank = nil; source = nil; revision = -1
    }
    func freeze() {
        let animation = CABasicAnimation(keyPath:"opacity"); animation.fromValue = layer?.presentation()?.opacity ?? 1
        animation.toValue = 0.45; animation.duration = 0.22
        layer?.opacity = 0.45; layer?.add(animation,forKey:"recording-stop")
    }
    func present(bank value: SpectrogramSurface, revision valueRevision: Int, displayMs: Double, reduced: Bool) {
        let bankChanged = bank !== value
        let changed = bankChanged || revision != valueRevision
        if bankChanged { source = RecordingSurfaceContents(value.surface) }
        bank = value; revision = valueRevision
        let width = CGFloat(style.columns), height = style == .pill ? CGFloat(9) : CGFloat(32)
        let capacity = CGFloat(style.columns+2), position = displayMs/style.slotMs
        let base = floor(position/Double(style.columns+2))*Double(style.columns+2)
        let origin = width-CGFloat(position-base)
        for index in lanes.indices {
            let lane = lanes[index], selected = style == .pill ? index : rowLane.rawValue
            lane.clip.frame = .init(x:0,y:style == .pill ? CGFloat(index)*11 : 0,width:width,height:height)
            lane.fade.frame = lane.clip.bounds; lane.clip.mask = reduced ? nil : lane.fade
            for image in [lane.first,lane.second] {
                image.bounds = .init(x:0,y:0,width:capacity,height:height)
                image.contentsRect = .init(x:0,y:Double(selected)/2,width:1,height:0.5)
                if changed { image.delegate = source; image.setNeedsDisplay() }
            }
            lane.first.position = .init(x:reduced ? 0 : origin,y:0)
            lane.second.position = .init(x:origin-capacity,y:0); lane.second.isHidden = reduced
        }
    }
}

/// Public CALayerDelegate display callbacks replace the nonexistent public
/// setContentsChanged selector. No CG backing store or full-image copy is made.
private final class RecordingSurfaceContents: NSObject, CALayerDelegate {
    private let surface: IOSurfaceRef
    init(_ surface: IOSurfaceRef) { self.surface = surface }
    func display(_ layer: CALayer) { layer.contents = surface }
}

struct RecordingSpectrogramStrip: NSViewRepresentable {
    let controller: RecordingSpectrogram?
    let lane: SpectrogramLane
    let silent: Bool
    @Environment(\.colorScheme) private var colourScheme
    func makeNSView(context: Context) -> RecordingSpectrogramView { .init(style:.row,lane:lane) }
    func updateNSView(_ view: RecordingSpectrogramView, context: Context) {
        view.configure(controller,dark:colourScheme == .dark,silent:silent)
    }
    static func dismantleNSView(_ view: RecordingSpectrogramView, coordinator: ()) { view.detach() }
}
