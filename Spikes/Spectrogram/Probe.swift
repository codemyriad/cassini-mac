// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import AVFoundation
import CassiniRecording
import CassiniBrowserControl
import CassiniSpectrogram
import CassiniKit
import Darwin
import ScreenCaptureKit

/// Disposable hosted runner only. Exercises the production sink/owner, utility
/// analyser and native view/display link with generated PCM, never devices.
@MainActor enum SpectrogramSelfTest {
    private enum Failure: Error { case check(String) }
    private static func require(_ condition: Bool, _ description: String) throws {
        if !condition { throw Failure.check(description) }
    }
    static func run() async {
        let e = ProcessInfo.processInfo.environment
        guard e["GITHUB_ACTIONS"] == "true", e["RUNNER_ENVIRONMENT"] == "github-hosted",
              let mode = argument("-SpectrogramCase"), ["A","B","C","D","E"].contains(mode) else { exit(78) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniSpectrogram-"+UUID().uuidString)
        var report: [String:Any] = [:]
        var driver: SpectrogramProbeInputs?
        do {
            let input = try await Task.detached { try SpectrogramProbeInputs(root:root,browser:mode == "D") }.value
            driver = input
            let controller = RecordingSpectrogram(originUptime:input.origin,observers:input.observers)
            let window = NSWindow(contentRect:.init(x:50,y:50,width:1120,height:720),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title = "Cassini spectrogram — private generated input"
            window.appearance = NSAppearance(named:.aqua)
            let content = NSView(frame:.init(x:0,y:0,width:1120,height:720)); content.wantsLayer = true
            window.contentView = content
            var strips: [RecordingSpectrogramView] = []
            func add(_ style: CassiniSpectrogram.SpectrogramStripStyle, _ lane: CassiniSpectrogram.SpectrogramLane, _ frame: NSRect) {
                let view = RecordingSpectrogramView(style:style,lane:lane); view.frame = frame
                content.addSubview(view); view.configure(controller,dark:false,silent:false); strips.append(view)
            }
            add(.pill,.me,.init(x:700,y:640,width:50,height:20))
            if mode != "A" {
                add(.row,.me,.init(x:600,y:400,width:200,height:32))
                add(.row,.others,.init(x:600,y:300,width:200,height:32))
            }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            input.start()
            if RecordingSpectrogram.enabled {
                try await wait("visible four-second history",controller:controller) {
                    controller.fixtureHistoryStartMs >= 0 && controller.fixtureHasSound(0,since:0) && controller.fixtureHasSound(1,since:0)
                }
            } else { try await input.waitForSamples(throughMs:4000) }
            if argument("-SpectrogramProfileOnly") == "1" {
                // Instruments may suspend an attached process. This separate
                // diagnostic keeps that effect outside every CPU/pacing gate.
                let began=ProcessInfo.processInfo.systemUptime
                try await input.waitForProgress(afterUptime:began+60)
                report=["diagnosticProfileOnly":true,"audioDevicesOpened":false,
                        "seconds":ProcessInfo.processInfo.systemUptime-began,
                        "analyzedFrames":controller.analyzedFrames,"frameCallbacks":controller.frameCallbacks]
                report["fixtureInput"] = input.diagnostics
                controller.stop(atMs:(ProcessInfo.processInfo.systemUptime-input.origin)*1000)
                strips.forEach {$0.detach()};window.orderOut(nil)
                try await input.finish();try? FileManager.default.removeItem(at:root)
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])+Data([10]))
                exit(0)
            }
            if argument("-SpectrogramAllocations") == "1" {
                // A separate process with MallocStackLogging enabled: never
                // contaminate the uninstrumented CPU/pacing measurement.
                guard let output=argument("-SpectrogramOutput") else { throw Failure.check("allocation output") }
                let bytes=controller.payloadBytes
                try await allocationSnapshot(output:output,phase:"visible")
                strips.forEach { $0.detach();$0.removeFromSuperview() };strips.removeAll()
                _ = await withCheckedContinuation { continuation in controller.engine.requestFrame(nowMs:0) { continuation.resume(returning:$0) } }
                try require(controller.surfaceBytes == 0 && controller.rawHistoryBytes == 0,"allocation test releases surfaces and picture history")
                try await allocationSnapshot(output:output,phase:"detached")
                window.orderOut(nil);try await input.finish()
                try? FileManager.default.removeItem(at:root)
                let result:[String:Any]=["audioDevicesOpened":false,"allocationStacksCollected":true,
                    "viewPayloadBytes":bytes,"detachReleasesSurfaces":true]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])+Data([10]))
                exit(0)
            }
            if mode == "C" {
                window.miniaturize(nil)
                try await wait("minimized renderer releases clocks and history",controller:controller) { window.isMiniaturized && controller.fixtureSuspended }
                _ = await withCheckedContinuation { continuation in controller.engine.requestFrame(nowMs:0) { continuation.resume(returning:$0) } }
            }
            if mode != "C" { try require(window.occlusionState.contains(.visible),"visible test window") }
            let initialFrames = controller.analyzedFrames, initialAnalysis = controller.analysisNanoseconds
            let initialLate = controller.lateColumns, initialDropped = controller.droppedColumns
            let initialBufferDrops = controller.droppedBuffers
            controller.resetFrameMeasurements()
            let cpuStart = processCPU(), began = ProcessInfo.processInfo.systemUptime
            let mainCPUStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            // CPU duration is the subject under measurement. Completion comes
            // from a real producer callback after the sixty-second interval;
            // a separate deadline can only fail, never complete, the run.
            try await input.waitForProgress(afterUptime:began+60)
            let mainCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-mainCPUStart
            let elapsed = ProcessInfo.processInfo.systemUptime-began, cpu = processCPU()-cpuStart
            let analysis = Double(controller.analysisNanoseconds-initialAnalysis)/1e9/elapsed*100
            // Implicit CA transactions commit after the paint callback. Include
            // all main-thread CPU, so batching cannot move work outside the gate.
            let drawing = Double(mainCPU)/1e9/elapsed*100
            let regions = Double(controller.drawingNanoseconds)/1e9/elapsed*100
            let hidden = mode == "C" || mode == "E"
            report = ["case":mode,"seconds":elapsed,"audioDevicesOpened":false,
                "input":"production RecordingSink"+(mode == "D" ? " + OwnedBrowserCapture.browserAudio" : ""),
                "chunkFrames":mode == "D" ? 8192 : 4096,"cpuCorePercent":cpu/elapsed*100,
                "measurementStartMs":(began-input.origin)*1000,"measurementEndMs":(began+elapsed-input.origin)*1000,
                "analysisCorePercent":analysis,"drawingCorePercent":drawing,"frameCallbacks":controller.frameCallbacks,
                "instrumentedDrawingCorePercent":regions,
                "framesApplied":controller.framesApplied,"skippedFrames":controller.skippedFrames,
                "p95FrameMs":controller.frameP95Ms,"maxFrameMs":controller.maxFrameIntervalMs,
                "analyzedFrames":controller.analyzedFrames-initialFrames,"lateColumns":controller.lateColumns-initialLate,
                "budgetPolicy":"D36.4","steadyStateColumns":SpectrogramHostedBudget.steadyColumns(seconds:elapsed),
                "lateColumnFraction":Double(controller.lateColumns-initialLate)/SpectrogramHostedBudget.steadyColumns(seconds:elapsed),
                "droppedColumns":controller.droppedColumns-initialDropped,
                "droppedBuffers":controller.droppedBuffers-initialBufferDrops,
                "lateTiming":controller.lateTiming.filter { $0.ordinal > initialLate }.map {
                    ["ordinal":Double($0.ordinal),"slot":Double($0.slot),"releasedThrough":Double($0.releasedThrough),
                     "arrivalMs":$0.arrivalMs,"delayMs":$0.delayMs]
                },
                "viewPayloadBytes":controller.payloadBytes,"surfaceAllocationBytes":controller.surfaceBytes,
                "surfaceRevisions":controller.surfaceRevision,"minimized":window.isMiniaturized,
                "reducedMotion":controller.usingReducedMotion,
                "displayDelayMs":controller.displayDelayMs,
                "indicatorEnabled":RecordingSpectrogram.enabled]
            if hidden {
                try require(controller.frameCallbacks == 0 && controller.analyzedFrames == initialFrames,"hidden/off does no analysis or display callbacks")
            } else {
                try require(controller.frameCallbacks > (mode == "A" ? 1000 : 2500) && controller.analyzedFrames > initialFrames,"production display and FFT callbacks (callbacks=\(controller.frameCallbacks), applied=\(controller.framesApplied), FFT=\(controller.analyzedFrames-initialFrames), reduced=\(controller.usingReducedMotion))")
                try require(controller.surfaceRevision > 50 && controller.surfaceBytes > 0,"native surfaces updated")
            }
            var gates=SpectrogramHostedBudget.evaluate(mode:mode,seconds:elapsed,analysis:analysis,drawing:drawing,
                p95:controller.frameP95Ms,maximum:controller.maxFrameIntervalMs,
                late:controller.lateColumns-initialLate,payload:controller.payloadBytes)
            gates["drops"]=controller.droppedColumns == initialDropped
            gates["inputDrops"]=controller.droppedBuffers == initialBufferDrops
            report["gates"]=gates
            if mode == "B" {
                // Verify pixels from this process's own window, after the CPU
                // measurement. A ring/seed counter alone cannot prove that CA
                // sees repeated writes to the same IOSurface object.
                let sounding = try await darkPixels(window:window,view:strips[2],name:"B-sound")
                let meBoundary = input.silence(microphoneOnly:true)
                try await wait("Me silence replaces visible history",controller:controller) { controller.fixtureIsSilent(0,since:meBoundary) }
                let meSilent = try await darkPixels(window:window,view:strips[1],name:"B-microphone-silent")
                let othersSounding = try await darkPixels(window:window,view:strips[2],name:"B-others-still-sounding")
                try require(meSilent <= 4 && othersSounding >= 100,"native lane crops keep silent Me separate from sounding Others (\(meSilent),\(othersSounding))")
                let silenceBoundary = input.silence()
                try await wait("Others silence replaces visible history",controller:controller) { controller.fixtureIsSilent(1,since:silenceBoundary) }
                let silent = try await darkPixels(window:window,view:strips[2],name:"B-silence")
                try require(sounding >= 100 && silent <= 4,"composited pixels follow live same-surface sound→silence (\(sounding)→\(silent))")
                report["liveCompositedInkPixels"] = ["sound":sounding,"silence":silent,"microphoneAfterMicSilence":meSilent,"othersAfterMicSilence":othersSounding]
            }
            if mode == "B" {
                let bothStyles = controller.surfaceBytes
                strips[1].isHidden = true; strips[2].isHidden = true; controller.reconcile()
                try require(controller.surfaceBytes > 0 && controller.surfaceBytes < bothStyles,"hidden page releases its surface while the pill keeps running")
                strips[1].isHidden = false; strips[2].isHidden = false; controller.reconcile()
                // Exercise subscription transitions separately from the60-second
                // measurement. Hidden views must stop, then restart on return.
                strips.forEach { $0.isHidden = true }; controller.reconcile()
                try await wait("last hidden view releases clocks and history",controller:controller) { controller.fixtureSuspended }
                _ = await withCheckedContinuation { continuation in controller.engine.requestFrame(nowMs:0) { continuation.resume(returning:$0) } }
                let hiddenCallbacks = controller.frameCallbacks
                try require(controller.surfaceBytes == 0 && controller.rawHistoryBytes == 0,"hiding the last view frees native surfaces and raw history")
                // Prove source work continues while the renderer is suspended.
                try await input.waitForSamples(throughMs:input.samplePositionMs+Double(input.chunkFrames)/48)
                try require(controller.frameCallbacks == hiddenCallbacks,"hidden views disconnect their display link")
                let hiddenImages = controller.framesApplied
                strips.forEach { $0.isHidden = false }; controller.reconcile()
                try await wait("visible renderer applies fresh frame",controller:controller) { controller.framesApplied > hiddenImages && controller.frameCallbacks > hiddenCallbacks && controller.surfaceBytes > 0 }
                try require(controller.frameCallbacks > hiddenCallbacks && controller.surfaceBytes > 0,"visible views restart from fresh history")
                report["hideShowReleasesAndRestarts"] = true
            }
            if mode == "B" {
                // State pictures use the production selection timeline, PCM
                // discontinuities, palette and freeze path after measurement.
                let warningRevision=controller.surfaceRevision
                controller.appearance(dark:false,silent:true)
                try await wait("Silent warning palette applied",controller:controller) { controller.surfaceRevision > warningRevision }
                _ = try await darkPixels(window:window,view:strips[1],name:"B-silent-warning")
                let now = { (ProcessInfo.processInfo.systemUptime-input.origin)*1000 }
                var events=[CaptureEvent(atMs:0,type:"selection",reason:"start",me:true,others:true),
                    CaptureEvent(atMs:now(),type:"selection",reason:"user",me:true,others:false)]
                controller.update(events:events)
                let offBoundary = events.last!.atMs!
                try await wait("not-recorded selection fills visible history",controller:controller) { controller.fixtureHistoryStartMs >= offBoundary }
                let dots=try await darkPixels(window:window,view:strips[2],name:"B-others-not-recorded")
                try require((60...130).contains(dots),"not-recorded Others is a dotted line (\(dots) pixels)")
                events.append(.init(atMs:now(),type:"selection",reason:"user",me:true,others:true))
                controller.update(events:events);controller.appearance(dark:false,silent:false)
                let soundBoundary = input.resumeSound()
                try await wait("restored sound fills visible history",controller:controller) {
                    controller.fixtureHistoryStartMs >= soundBoundary && controller.fixtureHasSound(1,since:soundBoundary)
                }
                let gapBoundary = input.dropOthers(true)
                // Two seconds of missing source PCM is the fixture's data,
                // measured in produced samples, rather than a settling sleep.
                try await input.waitForSamples(throughMs:gapBoundary+2000)
                let returnBoundary = input.dropOthers(false)
                try await wait("Others column after genuine PCM gap",controller:controller) { controller.fixtureHasSound(1,since:returnBoundary) }
                _ = try await darkPixels(window:window,view:strips[2],name:"B-dropout-and-return")
                let darkRevision=controller.surfaceRevision
                window.appearance=NSAppearance(named:.darkAqua);controller.appearance(dark:true,silent:false)
                try await wait("Dark palette applied",controller:controller) { controller.surfaceRevision > darkRevision }
                _ = try await darkPixels(window:window,view:strips[2],name:"B-recording-dark")
                report["scriptedStates"] = ["silentWarning","othersNotRecorded","dropoutAndReturn","dark"]
                try await motion(true,controller:controller)
                let ticks = controller.frameCallbacks, images = controller.framesApplied
                try await wait("Reduced Motion column update",controller:controller) { controller.framesApplied > images }
                try require(controller.usingReducedMotion && controller.frameCallbacks == ticks && controller.framesApplied > images,"real Reduced Motion uses the column timer without display-link callbacks")
                _ = try await darkPixels(window:window,view:strips[2],name:"B-reduced-motion")
                try await motion(false,controller:controller)
                let resumed = controller.frameCallbacks
                try await wait("Normal-motion display link resumes",controller:controller) { controller.frameCallbacks > resumed }
                try require(!controller.usingReducedMotion && controller.frameCallbacks > resumed,"real normal-motion setting restores the display link")
                report["realMotionTransition"] = true
            }
            // Freeze is exercised after measurement; layout/theme changes may
            // not clear its last image or restart its display clock.
            let stoppedCallbacks = controller.frameCallbacks
            var stoppedRevision = controller.surfaceRevision
            try await SpectrogramProbeEvent.transaction {
                controller.stop(atMs:(ProcessInfo.processInfo.systemUptime-input.origin)*1000)
                stoppedRevision = controller.surfaceRevision
                controller.reconcile(); controller.appearance(dark:true,silent:true)
            }
            try require(controller.frameCallbacks == stoppedCallbacks,"Stop disconnects the frame clock")
            if hidden { try require(strips.allSatisfy { $0.layer?.animation(forKey:"recording-stop") == nil },"Hidden/off Stop creates no fade animation") }
            if !hidden { try require(controller.surfaceRevision >= stoppedRevision && strips.allSatisfy { $0.layer?.opacity == 0.45 },"Stop freezes and fades visible strips") }
            report["stopDisconnectsAndFreezes"] = true
            report["fixtureInput"] = input.diagnostics
            if mode == "B" { _ = try await darkPixels(window:window,view:strips[2],name:"B-stopping") }
            strips.forEach { $0.detach() }; window.orderOut(nil)
            try require(controller.surfaceBytes == 0 && controller.rawHistoryBytes == 0,"detaching the last stopped view releases its frozen native surfaces and raw history")
            report["detachReleasesSurfaces"] = true
            try await input.finish()
            try? FileManager.default.removeItem(at:root)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])+Data([10]))
            exit(0)
        } catch {
            report["failure"] = String(describing:error)
            if let driver { report["fixtureInput"] = driver.diagnostics }
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {
                FileHandle.standardOutput.write(data+Data([10]))
            }
            if let driver { try? await driver.finish() }
            try? FileManager.default.removeItem(at:root)
            FileHandle.standardError.write(Data("Spectrogram probe failed: \(error)\n".utf8)); exit(1)
        }
    }
    private static func wait(_ description:String,controller:RecordingSpectrogram,until condition:@escaping () -> Bool) async throws {
        try await SpectrogramProbeEvent().wait(description,controller:controller,until:condition)
    }
    private static func motion(_ value: Bool, controller: RecordingSpectrogram) async throws {
        guard let directory=argument("-SpectrogramOutput") else { throw Failure.check("motion request directory") }
        let observed=controller.displayOptionsChanges
        let requestID = UUID().uuidString
        let folder = URL(fileURLWithPath:directory)
        let ack = folder.appendingPathComponent("motion-ack.json")
        let request=try JSONSerialization.data(withJSONObject:["reduceMotion":value,"pid":getpid(),"requestID":requestID])
        try request.write(to:URL(fileURLWithPath:directory).appendingPathComponent("motion-request.json"),options:.atomic)
        // XCTest changes System Settings on this disposable Mac. Both actual
        // display-options and application-activation notifications drive this.
        try await SpectrogramProbeEvent().wait("real system Reduce Motion setting did not reach the view",controller:controller,timeout:40,directory:folder) {
            guard let data=try? Data(contentsOf:ack),
                  let response=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  response["requestID"] as? String == requestID else { return false }
            return controller.displayOptionsChanges > observed &&
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == value &&
            controller.usingReducedMotion == value &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        }
    }
    private static func allocationSnapshot(output:String,phase:String) async throws {
        let pid=getpid()
        try await Task.detached(priority:.utility) {
            for (tool,arguments) in [("heap",["-noContent","-sumObjectFields",String(pid)]),
                                     ("malloc_history",[String(pid),"-allBySize"])] {
                let path=URL(fileURLWithPath:output).appendingPathComponent("allocations-\(phase)-\(tool).txt")
                guard FileManager.default.createFile(atPath:path.path,contents:nil) else { throw Failure.check("allocation output file") }
                let file=try FileHandle(forWritingTo:path);defer {try? file.close()}
                let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/"+tool);process.arguments=arguments
                var environment=ProcessInfo.processInfo.environment
                environment.removeValue(forKey:"MallocStackLogging");process.environment=environment
                process.standardOutput=file;process.standardError=file
                try process.run();process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw Failure.check("\(tool) allocation snapshot failed") }
            }
        }.value
    }
    private static func darkPixels(window: NSWindow, view: NSView, name: String) async throws -> Int {
        // This API only returns content already available to the current process
        // without TCC consent. Never enumerate/capture another app or a display.
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where:{ $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else {
            throw Failure.check("current-process screenshot window")
        }
        let filter = SCContentFilter(desktopIndependentWindow:own)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width); config.height = Int(window.frame.height)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false; config.captureMicrophone = false
        let image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        if let directory = argument("-SpectrogramOutput"),
           let png = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) {
            try png.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name+".png"))
        }
        let rect = window.convertToScreen(view.convert(view.bounds,to:nil))
        let sx = Double(image.width)/window.frame.width, sy = Double(image.height)/window.frame.height
        let crop = CGRect(x:(rect.minX-window.frame.minX)*sx,y:(window.frame.maxY-rect.maxY)*sy,
                          width:rect.width*sx,height:rect.height*sy).integral
        guard let strip = image.cropping(to:crop) else { throw Failure.check("own strip crop") }
        var rgba = [UInt8](repeating:0,count:200*32*4)
        return try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data:bytes.baseAddress,width:200,height:32,bitsPerComponent:8,bytesPerRow:800,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.check("own strip pixel conversion") }
            context.draw(strip,in:CGRect(x:0,y:0,width:200,height:32))
            return stride(from:0,to:bytes.count,by:4).reduce(0) { count,index in
                count + (bytes[index] < 200 && bytes[index+1] < 200 && bytes[index+2] < 200 ? 1 : 0)
            }
        }
    }
    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of:name), index+1 < args.count else { return nil }
        return args[index+1]
    }
    private static func processCPU() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
    }
}

/// No AVAudioEngine, AudioProcessTap, browser profile or network exists here.
/// A serial timer feeds prebuilt RAM buffers into the actual per-session paths.
private final class SpectrogramProbeInputs: @unchecked Sendable {
    let observers: RecordedPCMObservers, origin = ProcessInfo.processInfo.systemUptime
    private let sink: RecordingSink, owner: OwnedBrowserCapture?
    private let queue = DispatchQueue(label:"io.codemyriad.cassini.spectro-probe")
    private let errorLock = NSLock()
    private var failure: String?
    private var timer: DispatchSourceTimer?
    private var buffers: [AVAudioPCMBuffer] = [], pcm: [Data] = []
    private var frames = 0, sequence = 0
    private var othersMissing = false
    private var intentionalGapFrames: UInt64 = 0
    private let chunk: Int
    var chunkFrames: Int { chunk }
    var samplePositionMs: Double { queue.sync { Double(frames)/48 } }
    private struct ProgressWait {
        let ready: (Int, Double) -> Bool
        let continuation: CheckedContinuation<Void, Error>
        let deadline: DispatchWorkItem
    }
    private var progressWaits: [UUID:ProgressWait] = [:]
    private var skippedFixtureFrames: UInt64 = 0
    var diagnostics: [String:Any] {
        let fixture = queue.sync { (frames,intentionalGapFrames,skippedFixtureFrames) }
        let actual = sink.status()
        return ["producedThroughFrames":fixture.0,"intentionalGapFrames":fixture.1,
                "skippedFixtureFrames":fixture.2,"actualGapMs":actual.gapMs,
                "actualDroppedMs":actual.droppedMs,"warnings":actual.warnings]
    }
    private enum ProgressFailure: Error { case timeout(String), finished }
    func waitForSamples(throughMs target:Double) async throws {
        try await waitForProgress("producer sample position \(target) ms",timeout:15) { frames,_ in Double(frames)/48 >= target }
    }
    func waitForProgress(afterUptime target:Double) async throws {
        try await waitForProgress("sixty-second source progress",timeout:90) { _,uptime in uptime >= target }
    }
    private func waitForProgress(_ description:String,timeout:Double,until ready:@escaping (Int,Double) -> Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if ready(frames,ProcessInfo.processInfo.systemUptime) { continuation.resume(); return }
                let id = UUID()
                let deadline = DispatchWorkItem { [self] in
                    guard let wait = progressWaits.removeValue(forKey:id) else { return }
                    wait.continuation.resume(throwing:ProgressFailure.timeout(description))
                }
                progressWaits[id] = .init(ready:ready,continuation:continuation,deadline:deadline)
                queue.asyncAfter(deadline:.now()+timeout,execute:deadline)
            }
        }
    }
    init(root: URL, browser: Bool) throws {
        chunk = browser ? 8192 : 4096
        if browser {
            let capture = try OwnedBrowserCapture(parent:root,title:"Private generated meeting",microphone:true)
            owner = capture; observers = capture.pcmObservers
            sink = capture.nativeSink(side:.me,originHostTime:AVAudioTime.hostTime(forSeconds:origin),failure:{ _ in })
            for n in 0..<4 { try capture.browserTrack(id:"remote-\(n)",label:"Remote",kind:"remote",sampleRate:48000,channels:1) }
        } else {
            owner = nil
            let session = try RecordingSession(parent:root,title:"Private generated sound",source:"macos")
            observers = session.pcmObservers
            sink = RecordingSink(session:session,originHostTime:AVAudioTime.hostTime(forSeconds:origin),onFailure:{ _ in })
        }
        let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        for track in 0..<(browser ? 5 : 2) {
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(chunk))!
            buffer.frameLength = AVAudioFrameCount(chunk)
            for n in 0..<chunk { buffer.floatChannelData![0][n] = Float(0.05/Double(track+1)*sin(2*Double.pi*Double(400+track*300)*Double(n)/48000)) }
            buffers.append(buffer)
            pcm.append((0..<chunk).map { Int16((buffer.floatChannelData![0][$0]*32767).rounded()).littleEndian }.withUnsafeBytes { Data($0) })
        }
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue:queue); self.timer = timer
        // A one-shot is rearmed from the next integer sample boundary. A
        // repeating fractional-nanosecond period can drift ahead of that boundary
        // and defer a ready buffer by a whole85/170ms on the next repeat.
        timer.schedule(deadline:.now())
        timer.setEventHandler { [weak self] in self?.emit() }; timer.resume()
    }
    private func emit() {
        let clock=SpectrogramFixtureClock(chunk:chunk)
        let complete=clock.completeFrames(at:ProcessInfo.processInfo.systemUptime-origin)/chunk
        // Dispatch timers can coalesce wakeups. Advance on the sample clock,
        // rather than permanently delaying the source after one missed wakeup.
        // Bound catch-up to ten chunks; a longer stall becomes a real gap.
        if complete-frames/chunk > 10 {
            let resumed = (complete-10)*chunk
            skippedFixtureFrames += UInt64(resumed-frames)
            frames = resumed
        }
        while frames/chunk < complete { emitPacket() }
        if let timer {
            let remaining=clock.nextDelay(after:frames,elapsed:ProcessInfo.processInfo.systemUptime-origin)
            timer.schedule(deadline:.now()+remaining,leeway:.milliseconds(1))
        }
    }
    private func emitPacket() {
        let offset = Double(frames)/48, host = AVAudioTime.hostTime(forSeconds:origin+offset/1000)
        sink.receive(buffers[0],hostTime:host,id:"mic",label:"Mic",kind:"microphone")
        if othersMissing { intentionalGapFrames += UInt64(chunk) }
        else if let owner {
            do { for n in 0..<4 { try owner.browserAudio(id:"remote-\(n)",sequence:sequence,offsetMs:offset,pcm:pcm[n+1]) } }
            catch { errorLock.withLock { failure = String(describing:error) } }
        } else { sink.receive(buffers[1],hostTime:host,id:"system",label:"System",kind:"system") }
        frames += chunk; sequence += 1
        let uptime = ProcessInfo.processInfo.systemUptime
        for (id,wait) in progressWaits where wait.ready(frames,uptime) {
            progressWaits.removeValue(forKey:id); wait.deadline.cancel(); wait.continuation.resume()
        }
    }
    func silence(microphoneOnly: Bool = false) -> Double {
        queue.sync {
            for index in 0..<(microphoneOnly ? 1 : buffers.count) {
                for n in 0..<chunk { buffers[index].floatChannelData![0][n] = 0 }
                pcm[index] = Data(repeating:0,count:pcm[index].count)
            }
            return Double(frames)/48
        }
    }
    func dropOthers(_ value:Bool) -> Double { queue.sync { othersMissing=value; return Double(frames)/48 } }
    func resumeSound() -> Double {
        queue.sync {
            for (track,buffer) in buffers.enumerated() {
                for n in 0..<chunk { buffer.floatChannelData![0][n] = Float(0.05/Double(track+1)*sin(2*Double.pi*Double(400+track*300)*Double(n)/48000)) }
                pcm[track]=(0..<chunk).map { Int16((buffer.floatChannelData![0][$0]*32767).rounded()).littleEndian }.withUnsafeBytes { Data($0) }
            }
            return Double(frames)/48
        }
    }
    func finish() async throws {
        queue.sync {
            timer?.cancel(); timer = nil
            let waits = progressWaits; progressWaits.removeAll()
            for wait in waits.values { wait.deadline.cancel(); wait.continuation.resume(throwing:ProgressFailure.finished) }
        }
        let expected = queue.sync { intentionalGapFrames }
        do { try await Task.detached { [self] in try sink.finish(problem:nil) }.value }
        catch RecordingError.invalid(let message) {
            let status = sink.status()
            let gapMs = Double(expected)/48
            let exactDiagnostic = "Recording saved with \(Int(gapMs.rounded())) ms of host-time gap; the timeline contains silence."
            // Accept only the exact, counted fixture omission. Unexpected
            // scheduling gaps, writer losses and all other failures still fail.
            guard expected > 0, abs(status.gapMs-gapMs) < 1.0/48,
                  status.droppedMs == 0, message == exactDiagnostic else { throw RecordingError.invalid(message) }
        }
        if let owner { try await owner.finish() }
        if let failure = errorLock.withLock({ failure }) { throw RecordingError.invalid(failure) }
    }
}
#endif
