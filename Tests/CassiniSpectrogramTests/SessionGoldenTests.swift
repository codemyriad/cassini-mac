// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import os
import CassiniRecording
@testable import CassiniSpectrogram

@Suite struct SessionGoldenTests {
    private struct Golden: Decodable { let display: [[UInt8]] }
    private func render(_ session: SpectrogramSession, now: Double) async -> SpectrogramSession.Frame {
        await withCheckedContinuation { continuation in session.requestFrame(nowMs:now) { continuation.resume(returning:$0) } }
    }
    @Test(arguments:["spectro-v1","dc-quiet-jfk-v1"],[4096,8192])
    func admittedS16ThroughTheSessionMatchesBothUnchangedGoldens(_ name: String, chunk: Int) async throws {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let wave = try Data(contentsOf:root.appendingPathComponent(name+".wav"))
        var position = 12, pcm = Data()
        while position+8 <= wave.count {
            let size = wave.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:position+4,as:UInt32.self))) }
            guard size <= wave.count-position-8 else { throw CocoaError(.fileReadCorruptFile) }
            if String(data:wave.subdata(in:position..<position+4),encoding:.ascii) == "data" {
                pcm = wave.subdata(in:position+8..<position+8+size); break
            }
            position += 8+size+size%2
        }
        try #require(!pcm.isEmpty && pcm.count%2 == 0)
        let golden = try JSONDecoder().decode(Golden.self,from:Data(contentsOf:root.appendingPathComponent(name+".golden.json")))
        let time = OSAllocatedUnfairLock(initialState:0.0)
        let session = SpectrogramSession(clock:{ time.withLock { $0 } })
        let source = RecordedPCMSource(id:"reference-input",kind:"microphone",sampleRate:48000,channels:1,startOffsetMs:0)
        session.setVisible(true); _ = await render(session,now:0)
        var columns: [SpectrogramColumn] = []
        let frames = pcm.count/2
        for start in stride(from:0,to:frames,by:chunk) {
            let end = min(frames,start+chunk), now = Double(end)/48
            time.withLock { $0 = now }
            session.offer(source:source,pcm:pcm.subdata(in:start*2..<end*2),offsetMs:Double(start)/48)
            let picture = await render(session,now:now)
            columns += picture.me
            #expect(picture.droppedBuffers == 0 && picture.lateColumns == 0 && picture.droppedColumns == 0)
        }
        // Finish presentation of delayed columns without synthesizing more PCM.
        let final = await render(session,now:Double(frames)/48+2000)
        columns += final.me
        #expect(columns.count == golden.display.count)
        #expect(columns.map(\.slot) == (1...golden.display.count).map(Int64.init))
        let differences = zip(columns,golden.display).flatMap { value,expected in zip(value.bands,expected).map { abs(Int($0)-Int($1)) } }
        #expect(differences.max()! <= 3)
        #expect(Double(differences.filter { $0 <= 1 }.count)/Double(differences.count) >= 0.99)
        if name == "spectro-v1" { #expect(columns.filter { $0.slot <= 48 }.allSatisfy { $0.bands.allSatisfy { $0 == 0 } },"DC remains exactly blank through S16 conversion and lane release") }
    }
}
