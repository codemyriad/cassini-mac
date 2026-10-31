// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import AVFoundation
import CassiniRecording
import CassiniBrowserControl
import CassiniSpectrogram
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
            try await Task.sleep(for:.seconds(5))
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
            if mode == "C" { window.miniaturize(nil); try await Task.sleep(for:.seconds(1)) }
            if mode != "C" { try require(window.occlusionState.contains(.visible),"visible test window") }
            let initialFrames = controller.analyzedFrames, initialAnalysis = controller.analysisNanoseconds
            let initialLate = controller.lateColumns, initialDropped = controller.droppedColumns
            controller.resetFrameMeasurements()
            let cpuStart = processCPU(), began = ProcessInfo.processInfo.systemUptime
            let mainCPUStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            try await Task.sleep(for:.seconds(60))
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
                "analysisCorePercent":analysis,"drawingCorePercent":drawing,"frameCallbacks":controller.frameCallbacks,
                "instrumentedDrawingCorePercent":regions,
                "framesApplied":controller.framesApplied,"skippedFrames":controller.skippedFrames,
                "p95FrameMs":controller.frameP95Ms,"maxFrameMs":controller.maxFrameIntervalMs,
                "analyzedFrames":controller.analyzedFrames-initialFrames,"lateColumns":controller.lateColumns-initialLate,
                "droppedColumns":controller.droppedColumns-initialDropped,
                "viewPayloadBytes":controller.payloadBytes,"surfaceAllocationBytes":controller.surfaceBytes,
                "surfaceRevisions":controller.surfaceRevision,"minimized":window.isMiniaturized,
                "reducedMotion":controller.usingReducedMotion,
                "indicatorEnabled":RecordingSpectrogram.enabled]
            if hidden {
                try require(controller.frameCallbacks == 0 && controller.analyzedFrames == initialFrames,"hidden/off does no analysis or display callbacks")
            } else {
                try require(controller.frameCallbacks > (mode == "A" ? 1000 : 2500) && controller.analyzedFrames > initialFrames,"production display and FFT callbacks (callbacks=\(controller.frameCallbacks), applied=\(controller.framesApplied), FFT=\(controller.analyzedFrames-initialFrames), reduced=\(controller.usingReducedMotion))")
                try require(controller.surfaceRevision > 50 && controller.surfaceBytes > 0,"native surfaces updated")
            }
            report["gates"] = ["analysis":analysis <= 0.2,"drawing":drawing <= (mode == "A" ? 0.3 : 0.5),
                "pacing":mode == "A" || hidden || (controller.frameP95Ms <= 17.5 && controller.maxFrameIntervalMs <= 33),
                "late":controller.lateColumns == initialLate,"drops":controller.droppedColumns == initialDropped,
                "logicalViewPayload":controller.payloadBytes <= 128*1024]
            if mode == "B" {
                // Verify pixels from this process's own window, after the CPU
                // measurement. A ring/seed counter alone cannot prove that CA
                // sees repeated writes to the same IOSurface object.
                let sounding = try await darkPixels(window:window,view:strips[2],name:"B-sound")
                input.silence(microphoneOnly:true)
                try await Task.sleep(for:.seconds(5))
                let meSilent = try await darkPixels(window:window,view:strips[1],name:"B-microphone-silent")
                let othersSounding = try await darkPixels(window:window,view:strips[2],name:"B-others-still-sounding")
                try require(meSilent <= 4 && othersSounding >= 100,"native lane crops keep silent Me separate from sounding Others (\(meSilent),\(othersSounding))")
                input.silence()
                try await Task.sleep(for:.seconds(5)) // replace the whole4s history, including release
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
                try await Task.sleep(for:.milliseconds(250))
                let hiddenCallbacks = controller.frameCallbacks
                try require(controller.surfaceBytes == 0 && controller.rawHistoryBytes == 0,"hiding the last view frees native surfaces and raw history")
                try await Task.sleep(for:.milliseconds(250))
                try require(controller.frameCallbacks == hiddenCallbacks,"hidden views disconnect their display link")
                strips.forEach { $0.isHidden = false }; controller.reconcile()
                try await Task.sleep(for:.milliseconds(500))
                try require(controller.frameCallbacks > hiddenCallbacks && controller.surfaceBytes > 0,"visible views restart from fresh history")
                report["hideShowReleasesAndRestarts"] = true
            }
            if mode == "B" {
                try await motion(true,controller:controller)
                let ticks = controller.frameCallbacks, images = controller.framesApplied
                try await Task.sleep(for:.milliseconds(160))
                try require(controller.usingReducedMotion && controller.frameCallbacks == ticks && controller.framesApplied > images,"real Reduced Motion uses the column timer without display-link callbacks")
                try await motion(false,controller:controller)
                let resumed = controller.frameCallbacks
                try await Task.sleep(for:.milliseconds(160))
                try require(!controller.usingReducedMotion && controller.frameCallbacks > resumed,"real normal-motion setting restores the display link")
                report["realMotionTransition"] = true
            }
            // Freeze is exercised after measurement; layout/theme changes may
            // not clear its last image or restart its display clock.
            controller.stop(atMs:(ProcessInfo.processInfo.systemUptime-input.origin)*1000)
            let stoppedRevision = controller.surfaceRevision, stoppedCallbacks = controller.frameCallbacks
            controller.reconcile(); controller.appearance(dark:true,silent:true)
            try await Task.sleep(for:.milliseconds(250))
            try require(controller.frameCallbacks == stoppedCallbacks,"Stop disconnects the frame clock")
            if !hidden { try require(controller.surfaceRevision >= stoppedRevision && strips.allSatisfy { $0.layer?.opacity == 0.45 },"Stop freezes and fades visible strips") }
            report["stopDisconnectsAndFreezes"] = true
            strips.forEach { $0.detach() }; window.orderOut(nil)
            try require(controller.surfaceBytes == 0 && controller.rawHistoryBytes == 0,"detaching the last stopped view releases its frozen native surfaces and raw history")
            report["detachReleasesSurfaces"] = true
            try await input.finish()
            try? FileManager.default.removeItem(at:root)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])+Data([10]))
            exit(0)
        } catch {
            report["failure"] = String(describing:error)
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {
                FileHandle.standardOutput.write(data+Data([10]))
            }
            if let driver { try? await driver.finish() }
            try? FileManager.default.removeItem(at:root)
            FileHandle.standardError.write(Data("Spectrogram probe failed: \(error)\n".utf8)); exit(1)
        }
    }
    private static func motion(_ value: Bool, controller: RecordingSpectrogram) async throws {
        guard let directory=argument("-SpectrogramOutput") else { throw Failure.check("motion request directory") }
        let observed=controller.displayOptionsChanges
        let request=try JSONSerialization.data(withJSONObject:["reduceMotion":value,"pid":getpid()])
        try request.write(to:URL(fileURLWithPath:directory).appendingPathComponent("motion-request.json"),options:.atomic)
        // XCTest changes System Settings on this disposable Mac. Wait for the
        // real NSWorkspace notification and getter, never post it ourselves.
        let deadline=ContinuousClock.now.advanced(by:.seconds(40))
        while ContinuousClock.now < deadline {
            if controller.displayOptionsChanges > observed,
               NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == value,
               controller.usingReducedMotion == value,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        throw Failure.check("real system Reduce Motion setting did not reach the view")
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
    private let chunk: Int
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
        timer.schedule(deadline:.now(),repeating:Double(chunk)/48000,leeway:.milliseconds(1))
        timer.setEventHandler { [weak self] in self?.emit() }; timer.resume()
    }
    private func emit() {
        let offset = Double(frames)/48, host = AVAudioTime.hostTime(forSeconds:origin+offset/1000)
        sink.receive(buffers[0],hostTime:host,id:"mic",label:"Mic",kind:"microphone")
        if let owner {
            do { for n in 0..<4 { try owner.browserAudio(id:"remote-\(n)",sequence:sequence,offsetMs:offset,pcm:pcm[n+1]) } }
            catch { errorLock.withLock { failure = String(describing:error) } }
        } else { sink.receive(buffers[1],hostTime:host,id:"system",label:"System",kind:"system") }
        frames += chunk; sequence += 1
    }
    func silence(microphoneOnly: Bool = false) {
        queue.sync {
            for index in 0..<(microphoneOnly ? 1 : buffers.count) {
                for n in 0..<chunk { buffers[index].floatChannelData![0][n] = 0 }
                pcm[index] = Data(repeating:0,count:pcm[index].count)
            }
        }
    }
    func finish() async throws {
        queue.sync { timer?.cancel(); timer = nil }
        try await Task.detached { [self] in try sink.finish(problem:nil) }.value
        if let owner { try await owner.finish() }
        if let failure = errorLock.withLock({ failure }) { throw RecordingError.invalid(failure) }
    }
}
#endif
