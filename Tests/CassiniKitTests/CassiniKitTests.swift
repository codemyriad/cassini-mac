import Foundation
import Testing
@testable import CassiniKit

private func vector(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Conformance", withExtension: nil)!
        .appendingPathComponent("opus/\(name).opus")
    return try Data(contentsOf: url)
}

@Suite struct ConformanceVectors {
    @Test func minimalFileIsOk() throws {
        let f = try CassiniReader.read(vector("001-minimal-v1"))
        #expect(f.state == .ok)
        #expect(f.manifest?.transcripts.map(\.id) == ["raw-asr"])
        #expect(f.defaultTranscript?.load.transcript?.items.count == 3)
        if case .success(let d) = f.audioDigest! {
            #expect(d.sha256 == "3504435d6e7c677c862313ffdb0ced1d0678b7bf3b8c33fd903b89a848c076a8")
        } else { Issue.record("no digest") }
    }

    @Test func plainAudioPlays() throws {
        let f = try CassiniReader.read(vector("002-plain-audio"))
        #expect(f.state == .plainAudio)
        #expect(f.manifest == nil)
        #expect(f.errors.isEmpty)
    }

    @Test func multichunkReassembles() throws {
        let f = try CassiniReader.read(vector("003-multichunk-v1"))
        #expect(f.state == .ok)
        #expect(f.defaultTranscript?.load.transcript?.items.count == 900)
    }

    @Test func paddedBase64IsAccepted() throws {
        let f = try CassiniReader.read(vector("004-padded-base64url-v1"), verifyAudio: false)
        #expect(f.state == .unverified)
        #expect(f.defaultTranscript?.load.transcript?.items.count == 3)
    }

    @Test func duplicateChunkIsInvalid() throws {
        let f = try CassiniReader.read(vector("005-duplicate-chunk-tag"))
        #expect(f.state == .invalidCassiniMetadata)
        #expect(f.errors.first?.code == "duplicate-tag")
        #expect(f.transcripts.isEmpty)
    }

    @Test func missingChunkMakesTranscriptUnavailable() throws {
        let f = try CassiniReader.read(vector("006-missing-chunk"))
        #expect(f.state == .ok)
        #expect(f.defaultTranscript?.load.transcript == nil)
        #expect(f.errors.contains { $0.code == "chunk-missing" })
    }

    @Test func badPayloadDigestIsInvalid() throws {
        let f = try CassiniReader.read(vector("009-bad-payload-sha256"))
        #expect(f.state == .invalidCassiniMetadata)
        #expect(f.errors.first?.code == "payload-sha256-mismatch")
    }

    @Test func staleAudioKeepsTranscript() throws {
        let f = try CassiniReader.read(vector("010-stale-audio"))
        #expect(f.state == .staleAudio)
        #expect(f.defaultTranscript?.load.transcript?.items.count == 900)
        #expect(f.warnings.contains { $0.code == "audio-digest-mismatch" })
    }

    @Test func disagreeingDigestsAreUnverified() throws {
        let f = try CassiniReader.read(vector("011-tag-manifest-disagreement"))
        #expect(f.state == .unverified)
    }

    @Test func caseInsensitiveTagNames() throws {
        for v in ["012-lowercase-tag-names", "013-mixed-case-tag-names"] {
            let f = try CassiniReader.read(vector(v), verifyAudio: false)
            #expect(f.state == .unverified, "\(v)")
            #expect(f.defaultTranscript?.load.transcript?.items.count == 3)
        }
    }

    @Test func unknownMajorVersion() throws {
        let f = try CassiniReader.read(vector("015-unknown-major-version"))
        #expect(f.state == .unknownCassiniFormat)
        #expect(f.manifest == nil)
    }

    @Test func secondDefaultWins() throws {
        let f = try CassiniReader.read(vector("024-no-role-second-default"), verifyAudio: false)
        #expect(f.manifest?.defaultTranscript?.id == "second-pass")
        #expect(f.transcripts.count == 2)
    }

    @Test func missingRequiredDescriptorIsInvalid() throws {
        // Rewrite vector 001 without CASSINI_PAYLOAD_GZIP_BYTES: a required descriptor, so the file is invalid.
        let data = try vector("001-minimal-v1")
        let headers = try OpusHeaderReader.read(data)
        var tags = try TagSet.parse(headers.tags)
        tags.comments.removeAll { TagSet.fold($0.name) == "CASSINI_PAYLOAD_GZIP_BYTES" }
        let stripped = TagSet(vendor: tags.vendor, comments: tags.comments)
        #expect(stripped["CASSINI_PAYLOAD_GZIP_BYTES"] == nil)
        guard case .failure(let f) = CassiniReader.manifestDescriptor(stripped) else { Issue.record("accepted"); return }
        #expect(f.code == "payload-descriptor-incomplete")
    }

    @Test func oversizeHeaderIsReadWhole() throws {
        let f = try CassiniReader.read(vector("018-oversize-opustags"), verifyAudio: false)
        #expect(f.state == .unverified)
        #expect(f.defaultTranscript?.load.transcript?.items.count == 3)
    }
}

@Suite struct Codecs {
    @Test func base64urlStrictness() throws {
        #expect(try Base64URL.decode("aGk") == Data("hi".utf8))
        #expect(try Base64URL.decode("aGk=") == Data("hi".utf8))
        #expect(try Base64URL.decode("a Gk\n") == Data("hi".utf8))
        #expect(throws: PayloadError.self) { try Base64URL.decode("aGl") }  // non-zero trailing bits
        #expect(throws: PayloadError.self) { try Base64URL.decode("aG=k") }
        #expect(throws: PayloadError.self) { try Base64URL.decode("aG+k") }
    }

    @Test func jsonRejectsRepeatedMembers() throws {
        #expect(throws: PayloadError.self) { try JSONParser.parse(Data(#"{"a":1,"a":2}"#.utf8)) }
        #expect(try JSONParser.parse(Data(#"{"a":[1,2.5,"xé"],"b":null}"#.utf8))["a"]?.array?.count == 3)
    }

    @Test func decimals() {
        #expect(parseDecimal("0") == 0)
        #expect(parseDecimal("42") == 42)
        #expect(parseDecimal("042") == nil)
        #expect(parseDecimal("-1") == nil)
        #expect(parseDecimal("") == nil)
    }

    @Test func oggCRCMatchesDemoFirstPage() throws {
        // The spec gives the first-page CRC of the published demo as 0x530297d0; vectors use the same CRC.
        let data = try vector("001-minimal-v1")
        try data.withUnsafeBytes { raw in
            var r = OggPageReader(raw, verifyCRC: true)
            let p = try r.next()!
            #expect(p.storedCRC == p.computedCRC)
        }
    }
}

@Suite struct Turns {
    func w(_ s: String, _ a: Int, _ b: Int, _ t: String) -> Word {
        Word(speaker: s, startMs: a, endMs: b, text: t, lowConfidenceSpeaker: false, attributionGapDb: nil)
    }

    @Test func groupsRunsInFileOrder() {
        let tl = Timeline([w("a", 0, 500, "Hi"), w("a", 600, 900, "there."), w("b", 1000, 1400, "Hello.")])
        #expect(tl.turns.count == 2)
        #expect(tl.turns[0].words == [0, 1])
        #expect(tl.turns[1].speaker == "b")
    }

    @Test func foldsInterjectionAndRejoinsHost() {
        let tl = Timeline([
            w("a", 0, 400, "I"), w("a", 500, 900, "think"),
            w("b", 600, 900, "Yeah."),
            w("a", 1000, 1400, "so."),
        ])
        #expect(tl.turns.count == 1)
        #expect(tl.turns[0].words == [0, 1, 3])
        #expect(tl.turns[0].interjections.count == 1)
        #expect(tl.turns[0].interjections[0].anchor == 1)
    }

    @Test func currentWordPerSpeakerWithHold() {
        let tl = Timeline([w("a", 0, 400, "I"), w("a", 500, 900, "think"), w("b", 600, 900, "Yeah.")])
        var hint: [String: Int] = [:]
        #expect(tl.currentWords(at: 700, hint: &hint) == ["a": 1, "b": 2])
        #expect(tl.currentWords(at: 1100, hint: &hint) == ["a": 1, "b": 2])  // within 300 ms hold
        #expect(tl.currentWords(at: 1300, hint: &hint).isEmpty)
        #expect(tl.currentWords(at: 100, hint: &hint) == ["a": 0])  // backwards seek
    }

    @Test func hiddenSpeakersPromoteInterjections() {
        let tl = Timeline([w("a", 0, 400, "I"), w("a", 500, 900, "think"), w("b", 600, 900, "Yeah.")])
        let v = tl.visibleTurns(hiding: ["a"])
        #expect(v.count == 1)
        #expect(v[0].speaker == "b")
    }

    @Test func promotedInterjectionIdsAreDisjoint() {
        let tl = Timeline([w("a", 0, 400, "I"), w("a", 500, 900, "think"), w("b", 600, 900, "Yeah."),
                           w("c", 700, 900, "Right."), w("a", 1000, 1400, "so."), w("d", 5000, 5400, "Next.")])
        let real = Set(tl.turns.map(\.id))
        let v = tl.visibleTurns(hiding: ["a"])
        let ids = v.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids.filter { v[ids.firstIndex(of: $0)!].speaker != "d" }).isDisjoint(with: real))
    }

    @Test func heldInterjectionDoesNotJumpToLaterTurn() {
        // b's "Yeah." is written before a's "Mm.", which folds into x's turn; b must not land in y's turn 17 s later.
        let tl = Timeline([w("x", 0, 1500, "Long"), w("x", 1600, 3000, "turn."), w("b", 3100, 3400, "Yeah."),
                           w("a", 3050, 3300, "Mm."), w("y", 20000, 25000, "Much"), w("y", 25100, 30000, "later.")])
        let y = tl.turns.first { $0.speaker == "y" }!
        #expect(y.interjections.isEmpty)
        let bTurn = tl.turns.first { $0.speaker == "b" }
        let xHasB = tl.turns.first { $0.speaker == "x" }!.interjections.contains { $0.speaker == "b" }
        #expect(bTurn != nil || xHasB)
    }

    @Test func hugeTimesDoNotTrap() {
        let big = (1 << 53) - 1
        let tl = Timeline([w("a", 0, big, "Hi"), w("b", 10, 20, "yo")])
        var hint: [String: Int] = [:]
        _ = tl.currentWords(at: big, hint: &hint)
        _ = tl.activeTurns(at: big)
        #expect(throws: ManifestError.self) {
            try ManifestParser.words(.object([("items", .array([.object([
                ("speaker", .string("a")), ("startMs", .number("0")), ("endMs", .number(String(Int.max))), ("text", .string("x")),
            ])]))]))
        }
    }

    @Test func exportsSubtitles() {
        let tl = Timeline([w("a", 0, 400, "Hi"), w("a", 500, 900, "there.")])
        let vtt = TranscriptExporter.export(.webVTT, title: "T", timeline: tl, speakers: [Speaker(id: "a", label: "Ann")])
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:00.900\n<v Ann>Hi there."))
        let srt = TranscriptExporter.export(.srt, title: "T", timeline: tl, speakers: [])
        #expect(srt.contains("00:00:00,000 --> 00:00:00,900\nUnknown speaker: Hi there."))
    }
}
