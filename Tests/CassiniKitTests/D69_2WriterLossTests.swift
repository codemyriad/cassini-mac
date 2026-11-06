// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CassiniKit

/// D69.2: recognising D69's stored writer sentence and a writer-only recording from stored facts.
struct D69_2WriterLossTests {
    private let mic = WriterLoss.sentence(milliseconds:1000,kind:"microphone")
    private let system = WriterLoss.sentence(milliseconds:0,kind:"system")

    @Test func theSentenceIsD69s() {
        #expect(mic == "1000 ms of microphone audio was lost because the computer could not keep up; the gaps contain silence.")
    }
    @Test func onlyTrailingWriterSentencesAreStripped() {
        #expect(WriterLoss.strip(mic) == ("",1))
        #expect(WriterLoss.strip(mic+" "+system) == ("",2))
        #expect(WriterLoss.strip("Disk said no. "+mic) == ("Disk said no.",1))
        #expect(WriterLoss.strip(mic+" Disk said no.") == (mic+" Disk said no.",0),"a sentence before another diagnostic is not D69's tail")
        #expect(WriterLoss.strip("Some audio is missing: the recording has a gap of at least one second.").count == 0)
        #expect(WriterLoss.strip("x"+mic).count == 0,"a whole sentence only")
    }
    private func session(problem: String? = nil, tracks: String) -> JSON {
        try! JSONParser.parse(Data("""
        {"state":"interrupted","problemKind":"io","problem":\(problem.map { "\"\($0)\"" } ?? "\"\(mic)\""),"tracks":[\(tracks)]}
        """.utf8))
    }
    private let writer = #"{"id":"m","kind":"microphone","sampleRate":48000,"frames":144000,"receivedFrames":96000,"droppedFrames":48000,"gaps":[{"atMs":1000,"frames":48000,"kind":"writer"}]}"#

    @Test func writerOnlyFromStoredFacts() {
        #expect(WriterLoss.isWriterOnly(session(tracks:writer)))
        #expect(!WriterLoss.isWriterOnly(session(problem:"Disk said no. "+mic,tracks:writer)),"another diagnostic")
        #expect(!WriterLoss.isWriterOnly(session(problem:"Disk said no.",tracks:writer)),"no D69 sentence")
        #expect(!WriterLoss.isWriterOnly(session(tracks:writer.replacingOccurrences(of:#""kind":"microphone""#,with:#""kind":"microphone","problemKind":"io""#))),"a failed track")
        #expect(!WriterLoss.isWriterOnly(session(tracks:writer.replacingOccurrences(of:#""kind":"writer"}]"#,with:#""kind":"writer"},{"atMs":3000,"frames":48000,"kind":"input"}]"#))),"a 1 s input gap")
        #expect(WriterLoss.isWriterOnly(session(tracks:writer.replacingOccurrences(of:#""kind":"writer"}]"#,with:#""kind":"writer"},{"atMs":3000,"frames":47999,"kind":"input"}]"#))),"an input gap under 1 s")
        #expect(!WriterLoss.isWriterOnly(session(tracks:writer.replacingOccurrences(of:#""kind":"writer"}]"#,with:#""kind":"writer"},{"atMs":3000,"durationMs":1000,"kind":"jump"}]"#))),"a 1 s jump without frames")
        #expect(!WriterLoss.isWriterOnly(session(tracks:writer.replacingOccurrences(of:#""kind":"writer"}]"#,with:#""kind":"writer"},{"atMs":3000,"kind":"overflow"}],"gapFrames":48000"#))),"a long gap may hide after the overflow marker")
        #expect(!WriterLoss.isWriterOnly(session(tracks:#"{"id":"m","kind":"microphone","sampleRate":48000,"frames":48000,"gapFrames":100}"#)),"counted gaps without ranges")
        #expect(!WriterLoss.isWriterOnly(session(tracks:writer.replacingOccurrences(of:#""receivedFrames":96000"#,with:#""receivedFrames":0"#))),"nothing received")
        var completed = session(tracks:writer)
        if case .object(var members) = completed { members[0] = ("state",.string("completed")); completed = .object(members) }
        #expect(!WriterLoss.isWriterOnly(completed),"only an interrupted file needs this")
    }
    @Test func roundingIsExactHalfUpAcrossRates() {
        #expect(WriterLoss.roundedMilliseconds([48000:47_975]) == 999)
        #expect(WriterLoss.roundedMilliseconds([48000:47_976]) == 1000)
        #expect(WriterLoss.roundedMilliseconds([48000:24_000,44100:22_050]) == 1000)
        #expect(WriterLoss.roundedMilliseconds([:]) == 0)
    }
}
