// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
@testable import CassiniSpectrogram

@Suite struct SpectrumTests {
    private struct Golden: Decodable {
        let spec: String, rate: Int, n: Int, hop: Int, bands: Int
        let raw: [[Int]], display: [[Int]], firstFrame: Int
    }
    @Test func allocationReducedReleaseMatchesTheOriginalScalarOperationsExactly() {
        var release = SpectrogramRelease(), previous: Int64?, held: [Double] = []
        for n in 0..<512 {
            let slot = Int64(n+n/17)
            let powers = (0..<32).map { band -> Double in
                if (n+band)%41 == 0 { return .infinity }
                if (n+band)%43 == 0 { return .nan }
                return pow(10,Double((n*7+band*13)%145-125)/10)
            }
            let db = powers.map { value -> Double in
                if !value.isFinite { return value > 0 ? -20 : -120 }
                return 10*log10(max(value,1e-12))
            }
            held = previous.map { slot == $0+1 } == true ? zip(db,held).map { max($0,$1-3) } : db
            let expected = held.map { UInt8((255*min(1,max(0,($0+80)/60))).rounded(.toNearestOrEven)) }
            #expect(release.column(slot:slot,powers:powers) == expected)
            previous = slot
            if n%113 == 0 { release.reset(); previous = nil; held = [] }
        }
    }
    @Test func fixtureBytesRemainBoundToTheReference() throws {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let pin = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("UPSTREAM.json"))) as? [String:Any])
        let files = try #require(pin["files"] as? [String:String])
        #expect(files.count == 4)
        for (name,expected) in files {
            let actual = SHA256.hash(data:try Data(contentsOf:root.appendingPathComponent(name))).map { String(format:"%02x",$0) }.joined()
            #expect(actual == expected,"Pinned fixture \(name)")
        }
    }
    @Test(arguments:["spectro-v1","dc-quiet-jfk-v1"],[4096,8192])
    func nativeFFTMatchesTheUnchangedReference(_ name: String, chunkSize: Int) throws {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let samples = try wave(root.appendingPathComponent(name+".wav"))
        let golden = try JSONDecoder().decode(Golden.self,from:Data(contentsOf:root.appendingPathComponent(name+".golden.json")))
        let parameters = try SpectrogramParameters()
        let transform = SpectrogramTransform(parameters:parameters)
        let track = SpectrogramTrack(parameters:parameters,startOffsetMs:0,transform:transform)
        var release = SpectrogramRelease(), deltas: [Int] = []
        let lane = SpectrogramLaneAccumulator()
        #expect(golden.spec == "cassini-spectro-v1")
        #expect(golden.rate == parameters.rate && golden.n == parameters.size && golden.hop == parameters.hop && golden.bands == 32)
        #expect(parameters.firstFrame == golden.firstFrame)
        var count = 0
        for offset in stride(from:0,to:samples.count,by:chunkSize) {
            let end = min(samples.count,offset+chunkSize)
            track.append(Array(samples[offset..<end]),atFrame:Int64(offset)) { frame in
                guard count < golden.raw.count else { Issue.record("Unexpected extra frame"); return }
                let raw = SpectrogramRelease.raw(powers:frame.powers)
                let shown = release.column(slot:frame.slot,powers:frame.powers)
                deltas += zip(raw,golden.raw[count]).map { abs(Int($0)-$1) }
                deltas += zip(shown,golden.display[count]).map { abs(Int($0)-$1) }
                lane.append(slot:frame.slot,trackIndex:0,powers:frame.powers)
                lane.release(through:frame.slot) { column in
                    deltas += zip(column.bands,golden.display[count]).map { abs(Int($0)-$1) }
                }
                if name == "spectro-v1", frame.sampleEnd <= 48000 || frame.sampleEnd-Int64(parameters.size) >= 4*48000 && frame.sampleEnd <= 5*48000 {
                    #expect(raw.allSatisfy { $0 == 0 },"DC and whole silent frames are exactly empty")
                }
                count += 1
            }
        }
        #expect(count == golden.raw.count && count == golden.display.count)
        #expect(deltas.max()! <= 3)
        #expect(Double(deltas.filter{$0 <= 1}.count)/Double(deltas.count) >= 0.99)
    }
    @Test func frameGridAndBandEdgesFollowTheRateTable() throws {
        let expected = [(16000,1024,320),(24000,1024,480),(44100,2048,882),(48000,2048,960),(96000,4096,1920)]
        for (rate,size,hop) in expected {
            let actual = try SpectrogramParameters(rate:rate)
            #expect(actual.size == size && actual.hop == hop)
        }
        let standard = try SpectrogramParameters()
        #expect(standard.firstFrame == 2)
        #expect(standard.slot(frameEnd:2880,startOffsetMs:0) == 1)
        #expect(standard.slot(frameEnd:2880,startOffsetMs:125) == 8)
        #expect(abs(SpectrogramParameters.edgesHz.first! - 80) < 1e-8)
        #expect(abs(SpectrogramParameters.edgesHz.last! - 8000) < 1e-8)
        #expect(throws:SpectrogramError.self) { try SpectrogramParameters(rate:0) }
    }
    @Test func fullScaleCoherentSineHasTheRightEnergyAndDCIsExactlyEmpty() throws {
        let p = try SpectrogramParameters(), transform = SpectrogramTransform(parameters:try SpectrogramParameters())
        let signal = (0..<p.size).map { Float(sin(2*Double.pi*44*Double($0)/Double(p.size))) }
        let total = transform.powers(frame:signal).reduce(0,+)
        #expect(abs(10*log10(total) - (-3.01029995664)) < 0.001)
        let dc = [Float](repeating:-2060.0/32768,count:p.size)
        #expect(transform.powers(frame:dc).allSatisfy{$0 == 0})
        #expect(transform.powers(frame:[Float](repeating:.nan,count:p.size)).allSatisfy{$0 == 0})
    }
    @Test func aGapResetsReleaseAndTheScaleDoesNotAmplifySilence() {
        let loud = [Double](repeating:0.001,count:32), zero = [Double](repeating:0,count:32)
        var release = SpectrogramRelease()
        let first = release.column(slot:1,powers:loud)
        let next = release.column(slot:2,powers:zero)
        #expect(first.allSatisfy{$0 == 212})
        #expect(next.allSatisfy{$0 == 200})
        #expect(release.column(slot:4,powers:zero).allSatisfy{$0 == 0})
        #expect(SpectrogramRelease.raw(powers:zero).allSatisfy{$0 == 0})
    }
    @Test func stationaryAudioAt44100KeepsItsLevel() throws {
        func power(rate: Int) throws -> Double {
            let p = try SpectrogramParameters(rate:rate)
            let transform = SpectrogramTransform(parameters:p)
            let signal = (0..<p.size).map { Float(0.02*sin(2*Double.pi*1000*Double($0)/Double(rate))) }
            return transform.powers(frame:signal)[10]
        }
        #expect(abs(10*log10(try power(rate:44100)/power(rate:48000))) < 1)
    }
    private func wave(_ url: URL) throws -> [Float] {
        let bytes = [UInt8](try Data(contentsOf:url))
        func u32(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p+1]) << 8 | Int(bytes[p+2]) << 16 | Int(bytes[p+3]) << 24 }
        var offset = 12
        while offset+8 <= bytes.count {
            let count = u32(offset+4)
            if String(bytes:bytes[offset..<offset+4],encoding:.ascii) == "data" {
                return stride(from:offset+8,to:offset+8+count,by:2).map { p in
                    Float(Int16(bitPattern:UInt16(bytes[p]) | UInt16(bytes[p+1]) << 8))/32768
                }
            }
            offset += 8 + count + count%2
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
