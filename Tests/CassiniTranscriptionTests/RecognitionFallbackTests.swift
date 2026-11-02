// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
import CassiniWhistle
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
    /// codex #108: silence is advanced without allocating it, exactly as feeding zeros.
    func testFeedingSilenceMatchesFeedingZerosFromAnyTail() {
        for lead in [0,1,300,511,512,700] {
            for count in [0,1,211,511,512,513,5000] {
                var zeros = F.ActivityMeter(), fast = F.ActivityMeter()
                let before = speech(2).prefix(lead).map { $0 }, after = speech(4)
                zeros.feed(before); fast.feed(before)
                zeros.feed([Float](repeating:0,count:count)); fast.feedSilence(count)
                zeros.feed(after); fast.feed(after)
                XCTAssertEqual(fast.codes,zeros.codes,"lead \(lead), silence \(count)"); XCTAssertEqual(fast.samples,zeros.samples)
            }
        }
    }
    func testALongExcludedPrefixThenRetainedAudio() {
        // Four hours is a whole number of frames, so the audio after it frames as on its own.
        let hours = 4 * 3600 * rate, audio = speech(40)
        XCTAssertEqual(hours % F.frame,0)
        var m = F.ActivityMeter(); m.feedSilence(hours); m.feed(audio)
        XCTAssertEqual(m.samples,hours + audio.count); XCTAssertEqual(m.codes.count,(hours + audio.count) / F.frame)
        let alone = meter(audio)
        XCTAssertEqual(m.thresholdDB().threshold,alone.thresholdDB().threshold,"Silent frames never set the floor")
        XCTAssertEqual(m.active().suffix(alone.codes.count),alone.active()[...]); XCTAssertEqual(m.activeSeconds(),alone.activeSeconds())
    }
    /// codex #108 (G11): a word starting past its audio, or crossing its end, keeps its text with
    /// both times clamped to that audio; it is never dropped.
    func testWordsPastOrAcrossTheEndAreClampedNotDropped() throws {
        typealias W = WhistleTranscript.Word
        let words = [W(word:"inside",start:1,end:2,probability:1), W(word:"cross",start:14.95,end:15.5,probability:1),
                     W(word:"past",start:15.1,end:15.2,probability:1), W(word:"far",start:40,end:41,probability:1)]
        let out = try MeetingTranscriber.clamped(words,startMs:60000,lengthMs:15000)
        XCTAssertEqual(out,[word("inside",61000,62000),word("cross",74950,75000),word("past",75000,75000),word("far",75000,75000)])
        XCTAssertThrowsError(try MeetingTranscriber.clamped([W(word:"x",start:2,end:1,probability:1)],startMs:0,lengthMs:15000))
        XCTAssertThrowsError(try MeetingTranscriber.clamped([W(word:"x",start:.nan,end:1,probability:1)],startMs:0,lengthMs:15000))
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
