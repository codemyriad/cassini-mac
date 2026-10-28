// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Carbon
import IOKit.pwr_mgt
import Observation

@MainActor @Observable final class RecordingPower {
    private(set) var held = false
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    func setRecording(_ active: Bool) {
        guard active != held else { return }
        if active {
            let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Cassini recording" as CFString, &assertion)
            held = status == kIOReturnSuccess
        } else {
            if assertion != 0 { IOPMAssertionRelease(assertion) }
            assertion = 0; held = false
        }
    }
    deinit { if assertion != 0 { IOPMAssertionRelease(assertion) } }
}

private let recordingHotKeySignature: OSType = 0x43415353
/// RegisterEventHotKey receives the app's own global shortcut without observing
/// other keystrokes or requesting Accessibility/Input Monitoring permission.
@MainActor @Observable final class RecordingShortcut {
    private(set) var choice = RecordingHotKey.saved
    static var glyph: String { RecordingRuntime.shared.shortcut.choice.glyph }
    private(set) var registered = false
    @ObservationIgnored private var keyReference: EventHotKeyRef?
    @ObservationIgnored private var eventReference: EventHandlerRef?
    @ObservationIgnored private var perform: (() -> Void)?
    func start(_ perform: @escaping () -> Void) {
        self.perform = perform
        guard !registered, installHandler() == noErr else { return }
        registered = RegisterEventHotKey(choice.code,choice.flags,
            EventHotKeyID(signature:recordingHotKeySignature,id:1),GetApplicationEventTarget(),0,&keyReference) == noErr
        if !registered { removeHandler() }
    }
    private func installHandler() -> OSStatus {
        if eventReference != nil { return noErr }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                identifier.signature == recordingHotKeySignature, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<RecordingShortcut>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.perform?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventReference)
    }
    private func removeHandler() {
        if let eventReference { RemoveEventHandler(eventReference) }
        eventReference = nil
    }
    /// Register the candidate before releasing the old key. A conflicting or
    /// reserved key cannot silently leave recording without its working shortcut.
    func change(to candidate: RecordingHotKey) -> OSStatus {
        guard candidate.valid else { return OSStatus(paramErr) }
        if candidate == choice, registered { return noErr }
        let handlerStatus = installHandler()
        guard handlerStatus == noErr else { return handlerStatus }
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(candidate.code,candidate.flags,
            EventHotKeyID(signature:recordingHotKeySignature,id:1),GetApplicationEventTarget(),0,&replacement)
        guard result == noErr, let replacement else { return result == noErr ? OSStatus(eventNotHandledErr) : result }
        if let keyReference { UnregisterEventHotKey(keyReference) }
        keyReference = replacement; registered = true; choice = candidate
        if let bytes = try? JSONEncoder().encode(candidate) { RecordingPreferences.defaults.set(bytes,forKey:"CassiniRecordingHotKey") }
        return noErr
    }
    func stop() {
        if let keyReference { UnregisterEventHotKey(keyReference) }
        if let eventReference { RemoveEventHandler(eventReference) }
        keyReference = nil; eventReference = nil; registered = false; perform = nil
    }
}

@MainActor final class RecordingRuntime {
    static let shared = RecordingRuntime()
    let power = RecordingPower()
    let shortcut = RecordingShortcut()
    private var started = false
    func start() {
        guard !started else { return }; started = true
        shortcut.start { RecordCoordinator.shared.requestFromAnywhere() }
        observe()
    }
    private func observe() {
        guard started else { return }
        let active = withObservationTracking { RecordingController.shared.isRecording || RecordingPageFixture.enabled } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        power.setRecording(active)
    }
    func stop() { started = false; shortcut.stop(); power.setRecording(false) }
}
