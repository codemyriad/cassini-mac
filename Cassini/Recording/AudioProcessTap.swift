import AVFoundation
import CoreAudio

struct AudioProcess: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
}

func audioCheck(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed (\(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        ])
    }
}

/// Owns the tap, private aggregate and IO callback as one lifetime. Never mutes playback.
final class AudioProcessTap {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var callback: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.codemyriad.cassini.audio-tap", qos: .userInitiated)

    static func processes() throws -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try audioCheck(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "Listing audio processes")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try audioCheck(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids), "Reading audio processes")
        return ids.compactMap { id in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle)
            return AudioProcess(id: id, name: "\(bundle?.takeRetainedValue() as String? ?? "Audio process") (PID \(pid))")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(processes: [AudioObjectID]?, onFormatChange: @escaping () -> Void,
               receive: @escaping (AVAudioPCMBuffer, UInt64) -> Void) throws -> AVAudioFormat {
        do {
            let description: CATapDescription
            if let processes {
                description = CATapDescription(stereoMixdownOfProcesses: processes)
            } else {
                var ownPID = ProcessInfo.processInfo.processIdentifier
                var ownObject: AudioObjectID = 0
                var size = UInt32(MemoryLayout<AudioObjectID>.size)
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                               UInt32(MemoryLayout<pid_t>.size), &ownPID, &size, &ownObject)
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownObject == 0 ? [] : [ownObject])
            }
            description.name = "Cassini Recording"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try audioCheck(AudioHardwareCreateProcessTap(description, &tap), "Creating audio tap")
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try audioCheck(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "Reading tap format")
            guard let format = AVAudioFormat(streamDescription: &asbd), format.commonFormat == .pcmFormatFloat32,
                  (1...2).contains(format.channelCount) else {
                throw NSError(domain: "Cassini", code: 1, userInfo: [NSLocalizedDescriptionKey: "The audio device uses an unsupported tap format."])
            }
            let original = asbd
            let tappedObject = tap
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                var current = AudioStreamBasicDescription()
                var bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                var property = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let status = AudioObjectGetPropertyData(tappedObject, &property, 0, nil, &bytes, &current)
                // Aggregate-device setup can announce the same format again. Only stop
                // when the callback's interpretation of the actual samples would change.
                if status != noErr || current.mSampleRate != original.mSampleRate
                    || current.mFormatID != original.mFormatID || current.mFormatFlags != original.mFormatFlags
                    || current.mChannelsPerFrame != original.mChannelsPerFrame
                    || current.mBytesPerFrame != original.mBytesPerFrame || current.mBitsPerChannel != original.mBitsPerChannel {
                    onFormatChange()
                }
            }
            try audioCheck(AudioObjectAddPropertyListenerBlock(tap, &address, queue, listener), "Monitoring the audio format")
            formatListener = listener
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Cassini Recording",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                  kAudioSubTapDriftCompensationKey: true]]
            ]
            try audioCheck(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Creating capture device")
            try audioCheck(AudioDeviceCreateIOProcIDWithBlock(&callback, device, queue) { _, input, time, _, _ in
                guard input.pointee.mNumberBuffers > 0, asbd.mBytesPerFrame > 0 else { return }
                let frames = input.pointee.mBuffers.mDataByteSize / asbd.mBytesPerFrame
                guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input) else { return }
                receive(buffer, time.pointee.mHostTime)
            }, "Installing audio callback")
            try audioCheck(AudioDeviceStart(device, callback), "Starting system audio")
            return format
        } catch { stop(); throw error }
    }

    func stop() {
        if let formatListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(tap, &address, queue, formatListener)
            self.formatListener = nil
        }
        if let callback {
            AudioDeviceStop(device, callback)
            AudioDeviceDestroyIOProcID(device, callback)
            self.callback = nil
        }
        queue.sync {} // all callback-owned buffers have been copied before returning
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    deinit { stop() }
}
