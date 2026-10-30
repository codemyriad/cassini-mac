// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import AVFoundation
import CassiniRecording
import CassiniBrowserControl
import CassiniSpectrogram
import Darwin

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
        var driver: SpectrogramProbeInputs?
        do {
            let input = try await Task.detached { try SpectrogramProbeInputs(root:root,browser:mode == "D") }.value
            driver = input
            let controller = RecordingSpectrogram(originUptime:input.origin,observers:input.observers)
            let window = NSWindow(contentRect:.init(x:50,y:50,width:1120,height:720),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title = "Cassini spectrogram — private generated input"
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
            if mode == "C" { window.miniaturize(nil); try await Task.sleep(for:.seconds(1)) }
            if mode != "C" { try require(window.occlusionState.contains(.visible),"visible test window") }
            let initialFrames = controller.analyzedFrames, initialAnalysis = controller.analysisNanoseconds
            let initialLate = controller.lateColumns, initialDropped = controller.droppedColumns
            controller.resetFrameMeasurements()
            let cpuStart = processCPU(), began = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for:.seconds(60))
            let elapsed = ProcessInfo.processInfo.systemUptime-began, cpu = processCPU()-cpuStart
            let analysis = Double(controller.analysisNanoseconds-initialAnalysis)/1e9/elapsed*100
            let drawing = Double(controller.drawingNanoseconds)/1e9/elapsed*100
            let hidden = mode == "C" || mode == "E"
            var report: [String:Any] = ["case":mode,"seconds":elapsed,"audioDevicesOpened":false,
                "input":"production RecordingSink"+(mode == "D" ? " + OwnedBrowserCapture.browserAudio" : ""),
                "chunkFrames":mode == "D" ? 8192 : 4096,"cpuCorePercent":cpu/elapsed*100,
                "analysisCorePercent":analysis,"drawingCorePercent":drawing,"frameCallbacks":controller.frameCallbacks,
                "framesApplied":controller.framesApplied,"skippedFrames":controller.skippedFrames,
                "p95FrameMs":controller.frameP95Ms,"maxFrameMs":controller.maxFrameIntervalMs,
                "analyzedFrames":controller.analyzedFrames-initialFrames,"lateColumns":controller.lateColumns-initialLate,
                "droppedColumns":controller.droppedColumns-initialDropped,
                "viewPayloadBytes":controller.payloadBytes,"surfaceAllocationBytes":controller.surfaceBytes,
                "surfaceRevisions":controller.surfaceRevision,"minimized":window.isMiniaturized,
                "indicatorEnabled":RecordingSpectrogram.enabled]
            if hidden {
                try require(controller.frameCallbacks == 0 && controller.analyzedFrames == initialFrames,"hidden/off does no analysis or display callbacks")
            } else {
                try require(controller.frameCallbacks > (mode == "A" ? 1000 : 2500) && controller.analyzedFrames > initialFrames,"production display and FFT callbacks")
                try require(controller.surfaceRevision > 50 && controller.surfaceBytes > 0,"native surfaces updated")
            }
            report["gates"] = ["analysis":analysis <= 0.2,"drawing":drawing <= (mode == "A" ? 0.3 : 0.5),
                "pacing":mode == "A" || hidden || (controller.frameP95Ms <= 17.5 && controller.maxFrameIntervalMs <= 33),
                "late":controller.lateColumns == initialLate,"drops":controller.droppedColumns == initialDropped,
                "logicalViewPayload":controller.payloadBytes <= 128*1024]
            if mode == "B" {
                // Exercise subscription transitions separately from the60-second
                // measurement. Hidden views must stop, then restart on return.
                strips.forEach { $0.isHidden = true }; controller.reconcile()
                try await Task.sleep(for:.milliseconds(250))
                let hiddenCallbacks = controller.frameCallbacks
                try require(controller.surfaceBytes == 0,"hiding the last view frees native surfaces")
                try await Task.sleep(for:.milliseconds(250))
                try require(controller.frameCallbacks == hiddenCallbacks,"hidden views disconnect their display link")
                strips.forEach { $0.isHidden = false }; controller.reconcile()
                try await Task.sleep(for:.milliseconds(500))
                try require(controller.frameCallbacks > hiddenCallbacks && controller.surfaceBytes > 0,"visible views restart from fresh history")
                report["hideShowReleasesAndRestarts"] = true
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
            try require(controller.surfaceBytes == 0,"detaching the last stopped view releases its frozen native surfaces")
            report["detachReleasesSurfaces"] = true
            try await input.finish()
            try? FileManager.default.removeItem(at:root)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])+Data([10]))
            exit(0)
        } catch {
            if let driver { try? await driver.finish() }
            try? FileManager.default.removeItem(at:root)
            FileHandle.standardError.write(Data("Spectrogram probe failed: \(error)\n".utf8)); exit(1)
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
    func finish() async throws {
        queue.sync { timer?.cancel(); timer = nil }
        try await Task.detached { [self] in try sink.finish(problem:nil) }.value
        if let owner { try await owner.finish() }
        if let failure = errorLock.withLock({ failure }) { throw RecordingError.invalid(failure) }
    }
}
#endif
