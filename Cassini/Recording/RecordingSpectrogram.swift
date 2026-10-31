// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuartzCore
import IOSurface
import SwiftUI
import CassiniRecording
import CassiniKit
import CassiniSpectrogram
import os
import Darwin

/// One display clock and surface pair per capture. The Library pill and both
/// page rows consume the same batch, avoiding competing drains or repeated FFTs.
@MainActor final class RecordingSpectrogram: NSObject {
    static let enabled = ProcessInfo.processInfo.environment["CASSINI_SPECTRO"] != "0"
    static let measuring: Bool = {
        #if DEBUG
        let e = ProcessInfo.processInfo.environment
        return e["GITHUB_ACTIONS"] == "true" && e["RUNNER_ENVIRONMENT"] == "github-hosted" &&
            CommandLine.arguments.contains("--spectrogram-self-test")
        #else
        return false
        #endif
    }()
    let engine: SpectrogramSession
    let originUptime: TimeInterval
    private let observers: RecordedPCMObservers?
    private struct Selection { let at: Double, me: Bool, others: Bool }
    private struct WeakView { weak var value: RecordingSpectrogramView? }
    @MainActor private final class LinkTarget: NSObject {
        weak var owner: RecordingSpectrogram?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private struct Notice { let center: NotificationCenter, token: NSObjectProtocol }
    private struct Cleanup: @unchecked Sendable {
        let link: CADisplayLink?
        let timer: Timer?
        let notifications: [Notice]
    }
    private var views: [UUID:WeakView] = [:]
    private var visibleViews: [WeakView] = []
    private var selections: [Selection]
    private var eventCount = -1
    private let target = LinkTarget()
    private var link: CADisplayLink?
    private var reducedTimer: Timer?
    private var timerInterval: TimeInterval = 0
    private var pageRate: Bool?
    private weak var clockView: RecordingSpectrogramView?
    private var notifications: [Notice] = []
    private var generation = 0, inFlight = false, running = false, stopped = false
    private var pageBank: SpectrogramSurface?, pillBank: SpectrogramSurface?
    private var pageRevision = 0, pillRevision = 0
    private final class Pixels {
        var mePage: SpectrogramPixelRing, othersPage: SpectrogramPixelRing
        var mePill: SpectrogramPixelRing, othersPill: SpectrogramPixelRing
        init(dark: Bool) {
            mePage = .init(style:.row,dark:dark); othersPage = .init(style:.row,dark:dark)
            mePill = .init(style:.pill,dark:dark); othersPill = .init(style:.pill,dark:dark)
        }
        var bytes: Int { mePage.storageBytes+othersPage.storageBytes+mePill.storageBytes+othersPill.storageBytes }
    }
    private var pixels: Pixels?
    private var lastPage: Int64 = -1, lastPill: Int64 = -1
    private var dark = false, silent = false, reduced = false
    private var appliedDark = false, appliedSilent = false, appliedReduced = false
    private var pageNeedsBake = true, pillNeedsBake = true
    private(set) var frameCallbacks: UInt64 = 0, framesApplied: UInt64 = 0
    private(set) var skippedFrames: UInt64 = 0, maxFrameIntervalMs = 0.0
    #if DEBUG
    private(set) var displayOptionsChanges: UInt64 = 0
    private(set) var displayDelayMs: Double = 0
    #endif
    private(set) var drawingNanoseconds: UInt64 = 0, analysisNanoseconds: UInt64 = 0
    private(set) var analyzedFrames: UInt64 = 0, lateColumns: UInt64 = 0, droppedColumns: UInt64 = 0
    private var lastAppliedTime: Double?
    private var intervals = [UInt32](repeating:0,count:512)
    private var intervalCount: UInt64 = 0
    private var lastDisplayMs = 0.0
    private var preview = false
    private static let signposts = OSLog(subsystem:"io.codemyriad.cassini",category:"Spectrogram display")

    init(originUptime: TimeInterval, observers: RecordedPCMObservers? = nil, me: Bool = true, others: Bool = true) {
        self.observers = observers
        self.originUptime = originUptime; engine = .init(originUptime:originUptime,measureCPU:Self.measuring)
        selections = [.init(at:0,me:me,others:others)]
        super.init(); target.owner = self
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification,
            NSWindow.didChangeScreenNotification,NSWindow.didChangeBackingPropertiesNotification,
            NSApplication.didHideNotification,NSApplication.didUnhideNotification]
        notifications = names.map { name in
            let token = NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.appearance(dark:self.dark,silent:self.silent); self.reconcile()
                }
            }
            return .init(center:.default,token:token)
        }
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                #if DEBUG
                self.displayOptionsChanges &+= 1
                #endif
                self.appearance(dark:self.dark,silent:self.silent); self.reconcile()
            }
        }
        notifications.append(.init(center:center,token:token))
    }
    deinit {
        engine.setVisible(false); observers?.set(nil)
        let cleanup = Cleanup(link:link,timer:reducedTimer,notifications:notifications)
        DispatchQueue.main.async {
            cleanup.link?.invalidate(); cleanup.timer?.invalidate()
            cleanup.notifications.forEach { $0.center.removeObserver($0.token) }
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
            if stopped { reconcile() }
        }
    }
    func stop(atMs: Double) {
        guard !stopped else { return }; stopped = true; running = false; engine.stop(atMs:atMs)
        generation += 1; link?.invalidate(); link = nil; reducedTimer?.invalidate(); reducedTimer = nil; clockView = nil; inFlight = false
        engine.setVisible(false); observers?.set(nil)
        for view in views.values.compactMap(\.value) { view.freeze() }
    }
    func reconcile() {
        if views.values.contains(where:{ $0.value == nil }) { views = views.filter { $0.value.value != nil } }
        let mapped = views.values.compactMap(\.value)
        let visible = mapped.filter(\.visibleForSpectrogram)
        visibleViews = visible.map { .init(value:$0) }
        for view in mapped where !view.visibleForSpectrogram { view.suspend() }
        let page = visible.contains { $0.style == .row }
        let primary: RecordingSpectrogramView?
        if let current = clockView, visible.contains(where:{ $0 === current }), !page || current.style == .row { primary = current }
        else { primary = visible.first(where:{ $0.style == .row }) ?? visible.first }
        if stopped {
            guard Self.enabled, !visible.isEmpty else {
                if !preview { resetPicture() }
                return
            }
            ensureBanks(visible)
            paint(me:[],others:[],displayMs:lastDisplayMs)
            if !preview { visible.forEach { $0.freeze() } }
            return
        }
        guard Self.enabled, let primary else {
            if running {
                generation += 1; running = false; inFlight = false; engine.setVisible(false); observers?.set(nil)
                link?.invalidate(); link = nil; reducedTimer?.invalidate(); reducedTimer = nil; clockView = nil; pageRate = nil
                resetPicture()
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
        ensureBanks(visible)
    }
    private func resetPicture() {
        pageBank = nil; pillBank = nil; lastPage = -1; lastPill = -1
        pixels = nil
        pageNeedsBake = true; pillNeedsBake = true
        for view in views.values.compactMap(\.value) { view.suspend() }
    }
    private func ensureBanks(_ visible: [RecordingSpectrogramView]) {
        if visible.contains(where:{ $0.style == .row }) {
            if pageBank == nil { pageBank = try? .init(style:.row); pageNeedsBake = true }
        } else { pageBank = nil; pageNeedsBake = true }
        if visible.contains(where:{ $0.style == .pill }) {
            if pillBank == nil { pillBank = try? .init(style:.pill); pillNeedsBake = true }
        } else { pillBank = nil; pillNeedsBake = true }
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
        let cpuStart = Self.measuring ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0
        defer { if Self.measuring { drawingNanoseconds &+= clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-cpuStart } }
        // Window/view notifications update membership synchronously. Re-querying
        // AppKit occlusion/visibleRect here can make a WindowServer IPC every
        // display frame; the display link already belongs to the visible set.
        guard running, !reduced else { return }
        let interval = OSSignpostID(log:Self.signposts,object:self)
        os_signpost(.begin,log:Self.signposts,name:"Spectrogram display link",signpostID:interval)
        defer { os_signpost(.end,log:Self.signposts,name:"Spectrogram display link",signpostID:interval) }
        frameCallbacks += 1; requestFrame(timestamp:value.timestamp)
    }
    private func reducedTick() {
        guard running, !stopped, reduced else { return }
        guard visibleViews.contains(where:{ $0.value?.visibleForSpectrogram == true }) else { reconcile(); return }
        requestFrame(timestamp:CACurrentMediaTime())
    }
    private func requestFrame(timestamp: Double) {
        guard !inFlight else { skippedFrames += 1; return }; inFlight = true
        let revision = generation
        engine.requestFrame(nowMs:max(0,(timestamp-originUptime)*1000)) { [weak self] frame in
            DispatchQueue.main.async {
                guard let self, self.generation == revision, self.running, !self.stopped else { return }
                self.inFlight = false; self.analyzedFrames = frame.analyzedFrames; self.analysisNanoseconds = frame.analysisNanoseconds
                #if DEBUG
                self.displayDelayMs = frame.delayMs
                #endif
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
        let cpuStart = Self.measuring ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0
        defer { if Self.measuring { drawingNanoseconds &+= clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-cpuStart } }
        let interval = OSSignpostID(log:Self.signposts,object:self)
        os_signpost(.begin,log:Self.signposts,name:"Spectrogram draw",signpostID:interval)
        defer { os_signpost(.end,log:Self.signposts,name:"Spectrogram draw",signpostID:interval) }
        let pixels: Pixels
        if let existing = self.pixels { pixels = existing }
        else { pixels = Pixels(dark:dark); self.pixels = pixels }
        lastDisplayMs = displayMs
        let pageEnd = Int64(floor(displayMs/20)), pillEnd = Int64(floor((displayMs-60)/80))
        if pageNeedsBake, let bank = pageBank {
            try? bank.withWritableColumns { writer in
                pixels.mePage.configure(dark:dark,silent:silent,reducedMotion:reduced) { writer.column(lane:.me,index:$0,pixels:$1) }
                pixels.othersPage.configure(dark:dark,silent:false,reducedMotion:reduced) { writer.column(lane:.others,index:$0,pixels:$1) }
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
                        pixels.mePage.append(slot:slot,bands:a,recorded:selected(.me,slot:slot)) { writer.column(lane:.me,index:$0,pixels:$1) }
                        pixels.othersPage.append(slot:slot,bands:b,recorded:selected(.others,slot:slot)) { writer.column(lane:.others,index:$0,pixels:$1) }
                    } else {
                        pixels.mePage.remember(slot:slot,bands:a,recorded:selected(.me,slot:slot))
                        pixels.othersPage.remember(slot:slot,bands:b,recorded:selected(.others,slot:slot))
                    }
                } }
            }
            if let bank = pageBank { try? bank.withWritableColumns { remember($0) }; pageRevision += 1 }
            else { remember(nil) }
            lastPage = pageEnd
        }
        if pillNeedsBake, let bank = pillBank {
            try? bank.withWritableColumns { writer in
                pixels.mePill.configure(dark:dark,silent:silent,reducedMotion:reduced) { writer.column(lane:.me,index:$0,pixels:$1) }
                pixels.othersPill.configure(dark:dark,silent:false,reducedMotion:reduced) { writer.column(lane:.others,index:$0,pixels:$1) }
            }; pillRevision += 1; pillNeedsBake = false
        }
        if pillEnd > lastPill {
            let first = max(0,max(lastPill+1,pillEnd-51))
            func remember(_ writer: SpectrogramSurface.Writer?) {
                if first <= pillEnd { for slot in first...pillEnd {
                    let times = (0..<4).map { slot*4+Int64($0) }
                    let a = SpectrogramPillPooling.bands(times.map { pixels.mePage.bandValues(at:$0) })
                    let b = SpectrogramPillPooling.bands(times.map { pixels.othersPage.bandValues(at:$0) })
                    let m = times.contains { selected(.me,slot:$0) }, o = times.contains { selected(.others,slot:$0) }
                    if let writer {
                        pixels.mePill.append(slot:slot,bands:a,recorded:m) { writer.column(lane:.me,index:$0,pixels:$1) }
                        pixels.othersPill.append(slot:slot,bands:b,recorded:o) { writer.column(lane:.others,index:$0,pixels:$1) }
                    } else { pixels.mePill.remember(slot:slot,bands:a,recorded:m); pixels.othersPill.remember(slot:slot,bands:b,recorded:o) }
                } }
            }
            if let bank = pillBank { try? bank.withWritableColumns { remember($0) }; pillRevision += 1 }
            else { remember(nil) }
            lastPill = pillEnd
        }
        for item in visibleViews {
            guard let view = item.value else { continue }
            let bank = view.style == .pill ? pillBank : pageBank
            if let bank { view.present(bank:bank,revision:view.style == .pill ? pillRevision : pageRevision,
                displayMs:view.style == .pill ? displayMs-60 : displayMs,reduced:reduced) }
        }
    }
    #if DEBUG && !SPECTROGRAM_PROBE
    private static var cachedPreview: (Int64,RecordingSpectrogram)?
    /// Only a hosted, sealed screenshot fixture can create this frozen image.
    /// It performs file/FFT work on a utility task, never opens an audio device.
    static func frozenPreview(atMs: Int64) -> RecordingSpectrogram? {
        guard LibraryLaunchContext.current.screenshot else { return nil }
        if let cachedPreview, cachedPreview.0 == atMs { return cachedPreview.1 }
        let value = RecordingSpectrogram(originUptime:0)
        value.preview = true; value.stopped = true
        cachedPreview = (atMs,value)
        let file = Bundle.main.resourceURL?.appendingPathComponent("Whistle/jfk.wav")
        Task { @MainActor [weak value] in
            let columns = await Task.detached(priority:.utility) { () -> [SpectrogramColumn] in
                guard let file, let data = try? Data(contentsOf:file), data.count > 44,
                      let parameters = try? SpectrogramParameters(rate:16000) else { return [] }
                // Same pinned mono PCM16 fixture used by HostedRecordingInputs.
                let count = min(64000,(data.count-44)/2)
                let samples: [Float] = data.withUnsafeBytes { bytes in
                    (0..<count).map { Float(Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:44+$0*2,as:Int16.self)))/32768 }
                }
                let transform = SpectrogramTransform(parameters:parameters)
                let track = SpectrogramTrack(parameters:parameters,startOffsetMs:Double(max(0,atMs-4000)),transform:transform)
                let lane = SpectrogramLaneAccumulator()
                var result: [SpectrogramColumn] = []
                track.append(samples,atFrame:0) { frame in
                    lane.append(slot:frame.slot,trackIndex:0,powers:frame.powers)
                    lane.release(through:frame.slot) { result.append($0) }
                }
                return result
            }.value
            guard let value else { return }
            value.paint(me:columns.map { .init(slot:$0.slot,bands:[UInt8](repeating:0,count:32)) },others:columns,
                        displayMs:Double(max(0,atMs-40)))
            value.reconcile()
        }
        return value
    }
    #endif
    #if DEBUG
    func resetFrameMeasurements() {
        frameCallbacks = 0; framesApplied = 0; skippedFrames = 0; maxFrameIntervalMs = 0
        intervals = [UInt32](repeating:0,count:512); intervalCount = 0; lastAppliedTime = nil
        drawingNanoseconds = 0
    }
    var frameP95Ms: Double {
        guard intervalCount > 0 else { return 0 }
        let target = UInt64(ceil(Double(intervalCount)*0.95)); var sum: UInt64 = 0
        for (index,count) in intervals.enumerated() { sum += UInt64(count); if sum >= target { return Double(index)/10 } }
        return 51.1
    }
    var usingReducedMotion: Bool { reduced }
    var rawHistoryBytes: Int { pixels?.bytes ?? 0 }
    var surfaceRevision: Int { pageRevision+pillRevision }
    var surfaceBytes: Int { (pageBank?.allocatedBytes ?? 0)+(pillBank?.allocatedBytes ?? 0) }
    #endif
    var payloadBytes: Int {
        (pageBank?.allocatedBytes ?? 0)+(pillBank?.allocatedBytes ?? 0)+(pixels?.bytes ?? 0)+intervals.count*4+selections.count*MemoryLayout<Selection>.stride+64*37*2
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
    private var reducedMode: Bool?
    private struct LaneLayers { let clip = CALayer(), scrolling = CAReplicatorLayer(), first = CALayer(), fade = CAGradientLayer() }
    private var lanes: [LaneLayers] = []
    init(style: SpectrogramStripStyle, lane: SpectrogramLane = .me) {
        self.style = style; rowLane = lane; super.init(frame:.zero)
        wantsLayer = true; setAccessibilityElement(false)
        // Disable implicit actions only on our layers. Let AppKit coalesce the
        // implicit transaction at its normal frame boundary, instead of forcing
        // an explicit CA/WindowServer commit from every paint callback.
        let actions: [String:CAAction] = ["position":NSNull(),"bounds":NSNull(),"contents":NSNull(),
            "contentsRect":NSNull(),"mask":NSNull(),"hidden":NSNull(),"opacity":NSNull(),
            "instanceCount":NSNull(),"instanceTransform":NSNull()]
        layer?.actions = actions
        for _ in 0..<(style == .pill ? 2 : 1) {
            let item = LaneLayers()
            for owned in [item.clip,item.scrolling,item.first,item.fade] { owned.actions = actions }
            item.clip.masksToBounds = true; item.clip.cornerRadius = 2
            item.scrolling.anchorPoint = .zero; item.clip.addSublayer(item.scrolling)
            item.first.anchorPoint = .zero; item.first.contentsGravity = .resize
            item.first.minificationFilter = .linear; item.first.magnificationFilter = .linear
            item.scrolling.addSublayer(item.first)
            item.fade.colors = [NSColor.clear.cgColor,NSColor.white.cgColor,NSColor.white.cgColor]
            item.fade.locations = [0,0.16,1]; item.fade.startPoint = .init(x:0,y:0.5); item.fade.endPoint = .init(x:1,y:0.5)
            layer?.addSublayer(item.clip); lanes.append(item)
        }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    // The picture is exclusively the owned sublayers. Avoid AppKit's draw(_:) /
    // bitmap backing path; updates already arrive through the surface delegate.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var visibleForSpectrogram: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) &&
            !NSApp.isHidden && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }
    func configure(_ value: RecordingSpectrogram?, dark: Bool, silent: Bool) {
        if controller !== value {
            controller?.remove(registrationID); suspend(); layer?.removeAnimation(forKey:"recording-stop"); layer?.opacity = 1
            controller = value; value?.add(self)
        }
        value?.appearance(dark:dark,silent:silent)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller?.reconcile() }
    override func viewDidHide() { super.viewDidHide(); controller?.reconcile() }
    override func viewDidUnhide() { super.viewDidUnhide(); controller?.reconcile() }
    override func layout() { super.layout(); controller?.reconcile() }
    func detach() { controller?.remove(registrationID); controller = nil; suspend() }
    func suspend() {
        guard source != nil || bank != nil else { return }
        for lane in lanes {
            lane.first.contents = nil;lane.first.delegate = nil
        }; bank = nil; source = nil; revision = -1; reducedMode = nil
    }
    func freeze() {
        guard layer?.opacity != 0.45 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { layer?.opacity = 0.45; return }
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
        let modeChanged = reducedMode != reduced
        reducedMode = reduced
        for index in lanes.indices {
            let lane = lanes[index], selected = style == .pill ? index : rowLane.rawValue
            if bankChanged {
            lane.clip.frame = .init(x:0,y:style == .pill ? CGFloat(index)*11 : 0,width:width,height:height)
            lane.fade.frame = lane.clip.bounds
                lane.scrolling.bounds = .init(x:0,y:0,width:capacity,height:height)
                // Two GPU instances share one texture leaf, halving contents
                // invalidations/exports while retaining the same wrap geometry.
                lane.scrolling.instanceTransform = CATransform3DMakeTranslation(-capacity,0,0)
            }
            if bankChanged || modeChanged {
                lane.clip.mask = reduced ? nil : lane.fade
                lane.scrolling.instanceCount = reduced ? 1 : 2
            }
            let image=lane.first
                if bankChanged {
                    image.bounds = .init(x:0,y:0,width:capacity,height:height)
                    image.contentsRect = .init(x:0,y:Double(selected)/2,width:1,height:0.5)
                    image.delegate = source
                }
                if changed { image.setNeedsDisplay() }
            if bankChanged {
                lane.first.position = .zero
            }
            lane.scrolling.position = .init(x:reduced ? 0 : origin,y:0)
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordingSpectrogramView, context: Context) -> CGSize? { .init(width:200,height:32) }
    static func dismantleNSView(_ view: RecordingSpectrogramView, coordinator: ()) { view.detach() }
}
