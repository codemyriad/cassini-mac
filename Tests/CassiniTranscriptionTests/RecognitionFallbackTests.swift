// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import CassiniTranscription

/// D52.4 R71 (M13): the literal cases of GNOME tests/test_recognition_fallback.py
/// (cassini-gnome#149 at 26c1b0a8) for the pure fallback rules.
final class RecognitionFallbackTests: XCTestCase {
    typealias F = RecognitionFallback
    private let rate = 16000
    private func tone(_ seconds: Int, level: Double = 0.25) -> [Double] {
        (0..<(seconds*rate)).map { level * sin(2 * .pi * 300 * Double($0) / Double(rate)) }
    }
    /// Speech-like bursts on even seconds: 0.2 s quiet onset, then 0.8 s loud.
    private func speech(_ seconds: Int, silent: [(Int,Int)] = [], dc: Double = 0) -> [Float] {
        var samples = tone(seconds)
        for second in 0..<seconds {
            let a = second*rate, b = (second+1)*rate
            if second % 2 == 1 || silent.contains(where:{ $0.0 <= second && second < $0.1 }) { for i in a..<b { samples[i] = 0 } }
            else { for i in a..<(a + rate/5) { samples[i] *= 0.02/0.25 } }
        }
        return samples.map { Float($0 + dc) }
    }
    private func meter(_ samples: [Float]) -> F.ActivityMeter { var m = F.ActivityMeter(); m.feed(samples); return m }
    private func word(_ text: String, _ start: Int64, _ end: Int64) -> F.Word { .init(text:text,startMs:start,endMs:end) }

    func testActivityFloorComesFromAudibleFramesOnly() {
        let m = meter(speech(40))
        let t = m.thresholdDB(); XCTAssertEqual(t.floor,-37); XCTAssertEqual(t.threshold,-25)
        XCTAssertTrue((16...17).contains(m.activeSeconds()),"\(m.activeSeconds())")
        // Too few audible frames for a floor: -50 dBFS applies alone.
        let sparse = meter(speech(32,silent:[(4,32)]))
        XCTAssertNil(sparse.thresholdDB().floor); XCTAssertEqual(sparse.thresholdDB().threshold,-50)
        XCTAssertEqual(F.activeWindows(sparse.samples,active:sparse.active()),[0..<240000])
    }
    func testFeedingInBlocksMatchesOneBlockAndDCIsRemoved() {
        let whole = speech(40)
        var blocks = F.ActivityMeter()
        for start in stride(from:0,to:whole.count,by:7919) { blocks.feed(Array(whole[start..<min(whole.count,start+7919)])) }
        XCTAssertEqual(blocks.codes,meter(whole).codes)
        XCTAssertEqual(meter(speech(40,dc:0.1)).activeSeconds(),meter(whole).activeSeconds())
    }
    func testSteadyNoiseAndIsolatedClicksAreNeverActiveSpeech() {
        var state: UInt64 = 1
        func uniform() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
        func gaussian() -> Double { (-2*log(max(uniform(),1e-300))).squareRoot() * cos(2 * .pi * uniform()) }
        let noise = (0..<(40*rate)).map { _ in Float(gaussian() * 0.0056) }   // about -45 dBFS
        let n = meter(noise).thresholdDB(); XCTAssertEqual(n.floor,-45); XCTAssertEqual(n.threshold,-33)
        XCTAssertLessThan(meter(noise).activeSeconds(),F.minActiveSeconds)
        var clicks = (0..<(40*rate)).map { _ in Float(gaussian() * 0.001) }
        for start in stride(from:0,to:40*rate,by:1024) { for i in start..<start+80 { clicks[i] = 0.5 } }
        XCTAssertLessThan(meter(clicks).activeSeconds(),F.minActiveSeconds,"isolated clicks are not speech")
    }
    func testWindowBounds() {
        XCTAssertEqual(F.windowBounds(0),[]); XCTAssertEqual(F.windowBounds(100),[0..<100])
        XCTAssertEqual(F.windowBounds(40*rate),[0..<240000,232000..<472000,464000..<640000])
    }
    func testEnergyGateDropsWordsOverSilenceAndADCOnlyWindow() {
        let samples = tone(1).map(Float.init) + [Float](repeating:0,count:2*rate)
        let words = [word("speech",1300,1600),word("edge",2050,2100),word("silence",2400,2900)]
        XCTAssertEqual(F.energetic(words,samples:samples,baseMs:1000).map(\.text),["speech","edge"])
        XCTAssertEqual(F.energetic(words,samples:[Float](repeating:0.3,count:3*rate),baseMs:1000),[],"a constant offset is not energy")
    }
    func testSeamKeepsOneCopyOfAConfidentDuplicateFromTheSideWithMoreContext() {
        let merged = F.mergeSeam([word("hello",13800,14200),word("world",14560,14900)],[word("World.",14600,14950),word("again",15200,15500)],windowStartMs:14500,overlapMs:500)
        XCTAssertEqual(merged.map(\.text),["hello","World.","again"])
    }
    func testSeamPrefersATimedCopyAndAcceptsAConsistentWiderShift() {
        let following = [word("one",14850,15000),word("two",15030,15200)]
        XCTAssertEqual(F.mergeSeam([word("one",14520,14520),word("two",14700,14700)],following,windowStartMs:14500,overlapMs:500),following)
    }
    func testSeamDisagreementCutsAtTheOverlapMidpoint() {
        let merged = F.mergeSeam([word("before",14000,14300),word("cat",14600,14800)],[word("dog",14550,14700),word("hat",14800,14950),word("after",15100,15300)],windowStartMs:14500,overlapMs:500)
        XCTAssertEqual(merged.map(\.text),["before","cat","hat","after"])
    }
    func testSeamDoesNotTrustALoneMatchBeyondTwoHundredMs() {
        let previous = [word("yes",14550,14700)], following = [word("yes",14900,15000)]
        XCTAssertEqual(F.mergeSeam(previous,following,windowStartMs:14500,overlapMs:500),previous + following)
    }
    func testMargin() { XCTAssertEqual([0,1,5,9,20].map(F.need),[1,3,7,11,24]) }
    func testNormalization() {
        XCTAssertEqual(F.normal("“World.”"),"world"); XCTAssertEqual(F.normal("It’s"),"it's"); XCTAssertEqual(F.normal("..."),"")
    }
}
