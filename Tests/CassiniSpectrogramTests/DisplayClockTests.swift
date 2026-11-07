// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import CassiniSpectrogram

@Suite struct DisplayClockTests {
    @Test func maintainedPercentileMatchesAnIndependentBoundedWindow() {
        var clock = SpectrogramDisplayClock(), arrivals: [(at:Double,late:Double)] = []
        var expectedDelay = 40.0, target = 40.0, nextTarget = 0.0, previous: Double?
        for tick in 0..<3000 {
            let now = Double(tick)*7
            arrivals.removeAll { $0.at < now-3000 }
            for n in 0..<(tick%9) {
                let value = Double((tick*7+n*13)%500)
                clock.observe(columnMs:now-value,arrivalMs:now)
                arrivals.append((now,value))
                if arrivals.count > 1024 { arrivals.removeFirst() }
            }
            if now >= nextTarget {
                let values = arrivals.map(\.late).sorted()
                let p95 = values.isEmpty ? 0 : values[max(0,Int(ceil(Double(values.count)*0.95))-1)]
                target = min(2000,max(40,p95+20)); nextTarget = now+100
            }
            if let previous {
                expectedDelay = target > expectedDelay ? min(target,expectedDelay+(now-previous)*0.5) : max(target,expectedDelay-(now-previous)*0.02)
            }
            #expect(clock.advance(nowMs:now) == now-expectedDelay)
            #expect(clock.delayMs == expectedDelay)
            previous = now
        }
        // Expiry must remove every sorted occurrence, including duplicates.
        _ = clock.advance(nowMs:100000)
        #expect(clock.delayMs == 40)
    }
    @Test func commonDelayAbsorbsBrowserChunksAndShrinksAtTwoPercent() {
        var clock = SpectrogramDisplayClock()
        _ = clock.advance(nowMs:0)
        for now in stride(from:20.0,through:1000,by:20) {
            clock.observe(columnMs:now-230,arrivalMs:now)
            _ = clock.advance(nowMs:now)
        }
        #expect(clock.delayMs == 250)
        for now in stride(from:1020.0,through:5000,by:20) {
            clock.observe(columnMs:now-40,arrivalMs:now)
            let previous = clock.delayMs
            _ = clock.advance(nowMs:now)
            #expect(previous-clock.delayMs <= 0.400000001)
        }
        #expect(clock.delayMs < 250 && clock.delayMs > 220)
    }
    @Test func outliersExpireAndDelayRemainsBounded() {
        var clock = SpectrogramDisplayClock(); _ = clock.advance(nowMs:0)
        clock.observe(columnMs:0,arrivalMs:5000)
        #expect(clock.advance(nowMs:5000) == 3000)
        #expect(clock.delayMs == 2000)
        // No future timestamp or backwards tick can accelerate presentation.
        let previous = clock.advance(nowMs:5000)
        #expect(clock.advance(nowMs:4990) == previous)
        #expect(clock.advance(nowMs:.infinity) == 0)
        _ = clock.advance(nowMs:9000)
        #expect(abs(clock.delayMs-1920) < 1e-8)
        clock.reset(); #expect(clock.delayMs == 40)
    }
    @Test func percentileRejectsRareArrivalOutliers() {
        var clock = SpectrogramDisplayClock(); _ = clock.advance(nowMs:0)
        for n in 1...100 { clock.observe(columnMs:Double(n)*10-100,arrivalMs:Double(n)*10) }
        clock.observe(columnMs:0,arrivalMs:1001)
        _ = clock.advance(nowMs:1001)
        #expect(clock.delayMs == 120)
    }
    @Test func pillKeepsShortHighFrequencySyllablesAndDistinguishesHoles() throws {
        var a = [UInt8](repeating:0,count:32), b = a
        a[0] = 90; b[31] = 230
        let pooled = try #require(SpectrogramPillPooling.bands([a,nil,b,nil]))
        #expect(pooled[0] == 90 && pooled[15] == 230)
        #expect(pooled.dropFirst().dropLast().allSatisfy { $0 == 0 })
        #expect(SpectrogramPillPooling.bands([nil,nil,nil,nil]) == nil)
        #expect(SpectrogramPillPooling.bands([[UInt8](repeating:0,count:32),nil,nil,nil]) == [UInt8](repeating:0,count:16))
    }
}
