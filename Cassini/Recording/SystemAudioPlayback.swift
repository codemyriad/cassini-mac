// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import Foundation

/// D58.2 R2: whether another app is playing audio right now, from Core Audio's public process
/// objects (kAudioProcessPropertyIsRunningOutput). Cassini's own process never counts.
enum SystemAudioPlayback {
    static func anotherAppIsPlaying() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyProcessObjectList,
                                                 mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating:0,count:Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&ids) == noErr else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        return ids.contains { id in
            var pid: pid_t = 0, pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector:kAudioProcessPropertyPID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id,&pidAddress,0,nil,&pidSize,&pid) == noErr, pid != own else { return false }
            var running: UInt32 = 0, runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector:kAudioProcessPropertyIsRunningOutput,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(id,&runningAddress,0,nil,&runningSize,&running) == noErr && running != 0
        }
    }
}
