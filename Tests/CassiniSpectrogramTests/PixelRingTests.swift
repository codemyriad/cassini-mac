// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniSpectrogram

@Suite struct PixelRingTests {
    @Test func historyWithoutASurfaceRebakesExactlyTheSamePixels() {
        for style in [SpectrogramStripStyle.row,.pill] {
            var painted = SpectrogramPixelRing(style:style,dark:false)
            var history = SpectrogramPixelRing(style:style,dark:false)
            for n in 0..<600 {
                let slot = Int64(n+n/19)
                let bands = n%11 == 0 ? nil : [UInt8](repeating:UInt8(n%256),count:style.rows)
                painted.append(slot:slot,bands:bands,recorded:n%7 != 0) { _,_ in }
                history.remember(slot:slot,bands:bands,recorded:n%7 != 0)
                #expect(history.bandValues(at:slot) == painted.bandValues(at:slot))
            }
            for reduced in [false,true] {
                var a: [Int:[UInt32]] = [:], b: [Int:[UInt32]] = [:]
                painted.configure(dark:true,silent:true,reducedMotion:reduced) { a[$0] = $1 }
                history.configure(dark:true,silent:true,reducedMotion:reduced) { b[$0] = $1 }
                #expect(a == b)
            }
        }
    }
    @Test func premultipliedPixelsFollowTheSharedLightAndAmberTokens() {
        let normal = SpectrogramPalette(style:.row,dark:false,silent:false)
        #expect(normal.pixel(0) == 0x0f020202)
        #expect(normal.pixel(255) == 0xe71a1a1c)
        #expect(normal.dot == 0x660c0c0c)
        #expect(SpectrogramPalette(style:.row,dark:false,silent:true).pixel(0) == 0x3d2f1d00)
    }
    @Test func lowFrequenciesAreAtTheBottomAndHolesDifferFromSilenceAndOff() {
        var ring = SpectrogramPixelRing(style:.row,dark:false)
        var image: [Int:[UInt32]] = [:], bands = [UInt8](repeating:0,count:32); bands[0] = 255
        ring.append(slot:0,bands:bands,recorded:true) { image[$0] = $1 }
        #expect(image[0]?[31] == 0xe71a1a1c && image[0]?[0] == 0x0f020202)
        ring.append(slot:1,bands:nil,recorded:false) { image[$0] = $1 }
        #expect(image[1]?[16] == 0x660c0c0c && image[1]?.filter{$0 != 0}.count == 1)
        ring.append(slot:2,bands:nil,recorded:false) { image[$0] = $1 }
        #expect(image[2]?.allSatisfy{$0 == 0} == true)
        ring.append(slot:3,bands:nil,recorded:true) { image[$0] = $1 }
        #expect(image[3]?.allSatisfy{$0 == 0} == true)
    }
    @Test func wrapGapsAndReducedMotionRemainBoundedAndKeepTwoEmptyGuardColumns() {
        var ring = SpectrogramPixelRing(style:.pill,dark:false)
        var image: [Int:[UInt32]] = [:]
        for slot in 0..<200 {
            ring.append(slot:Int64(slot),bands:[UInt8](repeating:UInt8(slot),count:16),recorded:true) { image[$0] = $1 }
        }
        #expect(image.count == 52 && ring.storageBytes < 4096)
        #expect(ring.bandValues(at:199) == [UInt8](repeating:199,count:16))
        #expect(ring.bandValues(at:0) == nil,"Wrapped slots cannot masquerade as old history")
        let palette = SpectrogramPalette(style:.pill,dark:false,silent:false)
        for slot in 150..<200 { #expect(image[slot%52]?.allSatisfy{$0 == palette.pixel(UInt8(slot))} == true) }
        ring.configure(dark:false,silent:false,reducedMotion:true) { image[$0] = $1 }
        // 199 is the sweep head at49; its next two positions are the clear gap.
        #expect(image[0]?.allSatisfy{$0 == 0} == true && image[1]?.allSatisfy{$0 == 0} == true)
        for slot in 152..<200 { #expect(image[slot%50]?.allSatisfy{$0 == palette.pixel(UInt8(slot))} == true) }
        var writes = 0
        ring.append(slot:1_000_000,bands:nil,recorded:true) { image[$0] = $1; writes += 1 }
        #expect(writes <= 54 && image.values.allSatisfy { $0.allSatisfy{$0 == 0} })
    }
}
