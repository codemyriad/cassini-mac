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
    static let key: KeyEquivalent = "r"
    static let modifiers: SwiftUI.EventModifiers = [.option, .command]
    static var glyph: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + String(key.character).uppercased()
    }
    private(set) var registered = false
    @ObservationIgnored private var keyReference: EventHotKeyRef?
    @ObservationIgnored private var eventReference: EventHandlerRef?
    @ObservationIgnored private var perform: (() -> Void)?
    func start(_ perform: @escaping () -> Void) {
        guard eventReference == nil else { return }; self.perform = perform
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                identifier.signature == recordingHotKeySignature, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<RecordingShortcut>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.perform?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventReference)
        guard result == noErr else { return }
        registered = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey | cmdKey),
            EventHotKeyID(signature: recordingHotKeySignature, id: 1), GetApplicationEventTarget(), 0, &keyReference) == noErr
        if !registered { stop() }
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
