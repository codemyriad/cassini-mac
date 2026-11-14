// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioToolbox
import CassiniKit
import CryptoKit
import Darwin
import Foundation
import Testing
import zlib
@testable import CassiniLibrary

@Suite struct ImportTypesAndAudioDecodeTests {
    // MARK: - Helpers

    private static func oggPage(payload: Data, headerType: UInt8 = 0x02, serial: UInt32 = 1, seq: UInt32 = 0) -> Data {
        precondition(payload.count <= 255)
        var page = Data("OggS".utf8)
        page.append(0) // version
        page.append(headerType)
        page.append(contentsOf: [UInt8](repeating: 0, count: 8)) // granule
        var leSerial = serial.littleEndian
        var leSeq = seq.littleEndian
        withUnsafeBytes(of: &leSerial) { page.append(contentsOf: $0) }
        withUnsafeBytes(of: &leSeq) { page.append(contentsOf: $0) }
        page.append(contentsOf: [UInt8](repeating: 0, count: 4)) // checksum (ignored by header sniffer)
        page.append(1) // 1 segment
        page.append(UInt8(payload.count))
        page.append(payload)
        return page
    }

    private static func makeSyntheticWAV(
        to url: URL,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2,
        frames: AVAudioFrameCount = 22_050,
        floatPCM: Bool = false
    ) throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames))
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let phase = Double(i) * 2.0 * .pi * 440.0 / sampleRate
            let s = Float(sin(phase) * 0.4)
            for c in 0..<Int(channels) {
                buf.floatChannelData![c][i] = s * (c == 0 ? 1.0 : 0.6)
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: floatPCM ? 32 : 16,
            AVLinearPCMIsFloatKey: floatPCM,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: buf)
    }

    private static func makeSyntheticM4A(
        to url: URL,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2,
        frames: AVAudioFrameCount = 26_000,
        losslessALAC: Bool = false
    ) throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames))
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let s = Float(sin(Double(i) * 2.0 * .pi * 523.25 / sampleRate) * 0.35)
            for c in 0..<Int(channels) {
                buf.floatChannelData![c][i] = s
            }
        }
        var settings: [String: Any] = [
            AVFormatIDKey: losslessALAC ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if !losslessALAC {
            settings[AVEncoderBitRateKey] = 96_000
        }
        let out = try AVAudioFile(forWriting: url, settings: settings)
        try out.write(from: buf)
    }

    /// Synthesizes deterministic MPEG-1 Layer III (`44.1 kHz`, `128 kbps`, mono) frames, optionally prefixed with an ID3v2 tag.
    private static func makeSyntheticMP3(frameCount: Int = 40, withID3v2: Bool = false) -> Data {
        var data = Data()
        if withID3v2 {
            // Minimal 10-byte ID3v2.3 header with 0-byte body (synchsafe size 00 00 00 00)
            data.append(contentsOf: [0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }
        for i in 0..<frameCount {
            var frame = Data(repeating: 0, count: 417)
            frame[0] = 0xFF
            frame[1] = 0xFB // MPEG-1 Layer III, no CRC
            frame[2] = 0x90 // 128 kbps, 44.1 kHz, no padding
            frame[3] = 0xC4 // Mono
            // Vary ancillary byte slightly when desired while keeping main_data_begin == 0
            frame[416] = UInt8(i & 0xFF)
            data.append(frame)
        }
        return data
    }

    private static func makeStoredZip(_ entries: [(name: String, payload: Data)]) -> Data {
        func u16(_ v: UInt16) -> Data { var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) } }
        func u32(_ v: UInt32) -> Data { var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) } }
        func crc(_ d: Data) -> UInt32 {
            d.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return UInt32(zlib.crc32(0, base.assumingMemoryBound(to: Bytef.self), uInt(raw.count)))
            }
        }
        var archive = Data()
        var central = Data()
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let checksum = crc(entry.payload)
            let size = UInt32(entry.payload.count)
            let localOffset = UInt32(archive.count)

            archive.append(u32(0x0403_4b50))
            archive.append(u16(20))
            archive.append(u16(0x0800))
            archive.append(u16(0)) // stored
            archive.append(u16(0)); archive.append(u16(0))
            archive.append(u32(checksum))
            archive.append(u32(size))
            archive.append(u32(size))
            archive.append(u16(UInt16(nameBytes.count)))
            archive.append(u16(0))
            archive.append(nameBytes)
            archive.append(entry.payload)

            central.append(u32(0x0201_4b50))
            central.append(u16((3 << 8) | 20))
            central.append(u16(20))
            central.append(u16(0x0800))
            central.append(u16(0))
            central.append(u16(0)); archive.append(Data())
            central.append(u16(0))
            central.append(u32(checksum))
            central.append(u32(size))
            central.append(u32(size))
            central.append(u16(UInt16(nameBytes.count)))
            central.append(u16(0))
            central.append(u16(0))
            central.append(u16(0))
            central.append(u16(0))
            central.append(u32(UInt32(0o100644) << 16))
            central.append(u32(localOffset))
            central.append(nameBytes)
        }
        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(central.count)
        archive.append(central)
        archive.append(u32(0x0605_4b50))
        archive.append(u16(0))
        archive.append(u16(0))
        archive.append(u16(UInt16(entries.count)))
        archive.append(u16(UInt16(entries.count)))
        archive.append(u32(cdSize))
        archive.append(u32(cdOffset))
        archive.append(u16(0))
        return archive
    }

    // MARK: - 1. Vendored Contract Pin & Filtering

    @Test func vendoredImportTypesContractMatchesUpstreamCommitAndSHA256() throws {
        let f = try Fixture()
        let appUX = f.repository.appendingPathComponent("Cassini/Resources/UX")
        let pinData = try Data(contentsOf: appUX.appendingPathComponent("import-types-UPSTREAM.json"))
        let pin = try #require(JSONSerialization.jsonObject(with: pinData) as? [String: String])
        #expect(pin["repository"] == "cassini-ux")
        #expect(pin["path"] == "contract/import-types.json")
        #expect(pin["commit"] == "03fd3bb7dc806c015c1079807eaf5bc548a9fd42")
        #expect(pin["sha256"] == "bd80bb2b5ef176279ad6615e62960d19e693519867ab4fa0dded2d717584295d")

        let appBytes = try Data(contentsOf: appUX.appendingPathComponent("import-types.json"))
        let schemaBytes = try Data(contentsOf: f.repository.appendingPathComponent("Sources/CassiniLibrary/Schema/import-types.json"))
        let contract = ImportTypesContract.shared
        #expect(appBytes == schemaBytes)
        #expect(contract.rawBytes == appBytes)
        #expect(contract.sha256Hex == pin["sha256"])
    }

    @Test func contractConsumesOnlyDecidedTypesExcludesFlacAndAlignsWithInfoPlistAndProjectYML() throws {
        let f = try Fixture()
        let contract = ImportTypesContract.shared
        #expect(contract.decidedEntries.map(\.id) == ["opus-ogg", "mp3", "m4a", "wav"])
        #expect(contract.openEntries.map(\.id) == ["flac"])
        #expect(contract.decidedExtensions == [".opus", ".ogg", ".mp3", ".m4a", ".wav"])
        #expect(LibraryImport.supportedAudioExtensions == Set(["opus", "ogg", "mp3", "m4a", "wav"]))
        #expect(!LibraryImport.supportedAudioExtensions.contains("flac"))
        #expect(!LibraryImport.supportedAudioExtensions.contains("oga"))
        #expect(!LibraryImport.supportedAudioExtensions.contains("ogv"))

        #expect(contract.decidedUTIIdentifiers == [
            "org.xiph.opus",
            "org.xiph.ogg-audio",
            "public.mp3",
            "com.apple.m4a-audio",
            "public.mpeg-4-audio",
            "com.microsoft.waveform-audio",
        ])
        #expect(!contract.decidedUTIIdentifiers.contains("org.xiph.flac"))
        #expect(!contract.pickerMimeTypes.contains("audio/ogg"))
        #expect(!contract.pickerMimeTypes.contains("application/ogg"))
        #expect(!contract.pickerMimeTypes.contains("audio/flac"))

        let plistData = try Data(contentsOf: f.repository.appendingPathComponent("Cassini/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let docTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let declaredUTIs = Set(docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })
        for uti in contract.decidedUTIIdentifiers {
            #expect(declaredUTIs.contains(uti), "Missing decided UTI \(uti) in Info.plist CFBundleDocumentTypes")
        }
        #expect(declaredUTIs.contains("public.zip-archive"))
        #expect(!declaredUTIs.contains("org.xiph.flac"))

        for entry in docTypes {
            #expect(entry["CFBundleTypeRole"] as? String == "Viewer")
            #expect(entry["LSHandlerRank"] as? String == "Alternate")
        }

        let importedDecls = try #require(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let allDeclaredExts = Set(importedDecls.flatMap {
            (($0["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]) ?? []
        })
        #expect(!allDeclaredExts.contains("oga"))
        #expect(!allDeclaredExts.contains("flac"))

        let projectYML = try String(contentsOf: f.repository.appendingPathComponent("project.yml"), encoding: .utf8)
        for uti in contract.decidedUTIIdentifiers {
            #expect(projectYML.contains(uti), "Missing decided UTI \(uti) in project.yml")
        }
        #expect(!projectYML.contains("org.xiph.flac"))
        #expect(!projectYML.contains("- oga"))
    }

    // MARK: - 2. Content Validation Parity with cassini-ux

    @Test func contentValidationAcceptsValidOpusAndDecidedAudioWhileRejectingOggVideoAndFlac() throws {
        let f = try Fixture()
        let contract = ImportTypesContract.shared
        let opusHead = Data("OpusHead".utf8) + Data([0x01, 0x01, 0x38, 0x01, 0x80, 0xBB, 0x00, 0x00, 0x00, 0x00, 0x00])
        let opusTags = Data("OpusTags".utf8) + Data(repeating: 0, count: 8)
        let validOggOpus = Self.oggPage(payload: opusHead, headerType: 0x02, serial: 42, seq: 0)
            + Self.oggPage(payload: opusTags, headerType: 0x00, serial: 42, seq: 1)

        // Real Cassini conformance assets pass under both .opus and .ogg
        for asset in ["001-minimal-v1.opus", "002-plain-audio.opus", "016-two-transcripts.opus"] {
            let bytes = try Data(contentsOf: f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/\(asset)"))
            let probe = Data(bytes.prefix(contract.maxProbeBytes))
            #expect(contract.validateCandidate(fileName: asset, mimeType: "audio/opus", headerBytes: probe).typeID == "opus-ogg")
            #expect(contract.validateCandidate(fileName: "voice.ogg", mimeType: "audio/ogg", headerBytes: probe).typeID == "opus-ogg")
            #expect(contract.validateCandidate(fileName: "voice.ogg", mimeType: "application/ogg", headerBytes: probe).typeID == "opus-ogg")
            #expect(contract.validateCandidate(fileName: "voice.ogg", mimeType: nil, headerBytes: probe).typeID == "opus-ogg")
        }

        // Decided non-Ogg extensions
        #expect(contract.validateCandidate(fileName: "Episode.MP3", mimeType: "audio/mpeg").typeID == "mp3")
        #expect(contract.validateCandidate(fileName: "Memo.m4a", mimeType: "audio/mp4").typeID == "m4a")
        #expect(contract.validateCandidate(fileName: "Take.wav", mimeType: "audio/wav").typeID == "wav")

        // Ambiguous .ogg or compatibility MIME without header probe must be rejected
        #expect(!contract.validateCandidate(fileName: "ambiguous.ogg", mimeType: "audio/ogg", headerBytes: nil).accepted)
        #expect(!contract.validateCandidate(fileName: "ambiguous.ogg", mimeType: "audio/x-opus+ogg", headerBytes: nil).accepted)
        #expect(!contract.validateCandidate(fileName: "ambiguous.opus", mimeType: "audio/ogg", headerBytes: nil).accepted)
        #expect(!contract.validateCandidate(fileName: "ambiguous.opus", mimeType: "application/ogg", headerBytes: nil).accepted)

        // Ogg video, Skeleton, multiplexed Opus+Theora, Vorbis, Speex, FLAC, .oga, dotfiles
        let theoraBOS = Self.oggPage(payload: Data([0x80]) + Data("theora".utf8) + Data([0x03, 0x02, 0x01]) + Data(repeating: 0, count: 32))
        let ogmVideoBOS = Self.oggPage(payload: Data([0x01]) + Data("video\0\0\0".utf8) + Data(repeating: 0, count: 32))
        let skeletonBOS = Self.oggPage(payload: Data("fishead\0".utf8) + Data(repeating: 0, count: 56))
        let diracBOS = Self.oggPage(payload: Data("BBCD\0".utf8) + Data(repeating: 0, count: 24))
        let daalaBOS = Self.oggPage(payload: Data([0x80]) + Data("daala".utf8) + Data(repeating: 0, count: 24))
        let vorbisBOS = Self.oggPage(payload: Data([0x01]) + Data("vorbis".utf8) + Data(repeating: 0, count: 23))
        let speexBOS = Self.oggPage(payload: Data("Speex   ".utf8) + Data(repeating: 0, count: 72))
        let oggFlacBOS = Self.oggPage(payload: Data([0x7F]) + Data("FLAC".utf8) + Data([0x01, 0x00, 0x00, 0x01]) + Data("fLaC".utf8) + Data(repeating: 0, count: 34))
        let rawFlacHeader = Data("fLaC".utf8) + Data(repeating: 0, count: 38)
        let opusOnlyBOS = Self.oggPage(payload: opusHead, headerType: 0x02, serial: 1, seq: 0)
        let muxOpusTheora = opusOnlyBOS + Self.oggPage(
            payload: Data([0x80]) + Data("theora".utf8) + Data([0x03, 0x02, 0x01]) + Data(repeating: 0, count: 32),
            headerType: 0x02,
            serial: 2,
            seq: 0
        )

        let rejectedCases: [(String, String, String?, Data?)] = [
            ("ogv video/ogg", "clip.ogv", "video/ogg", theoraBOS),
            ("ogv application/ogg", "clip.ogv", "application/ogg", validOggOpus),
            ("Theora in .ogg", "clip.ogg", "audio/ogg", theoraBOS),
            ("Theora in .opus", "clip.opus", "audio/opus", theoraBOS),
            ("OGM video in .ogg", "clip.ogg", "audio/ogg", ogmVideoBOS),
            ("Dirac video in .ogg", "clip.ogg", "audio/ogg", diracBOS),
            ("Daala video in .ogg", "clip.ogg", "audio/ogg", daalaBOS),
            ("Skeleton .ogx", "mux.ogx", "application/ogg", skeletonBOS),
            ("Skeleton in .ogg", "mux.ogg", "application/ogg", skeletonBOS),
            ("Multiplexed Opus+Theora in .ogg", "mux-av.ogg", "audio/ogg", muxOpusTheora),
            ("MP4 video MIME on .m4a", "video.m4a", "video/mp4", nil),
            ("Vorbis in .ogg", "song.ogg", "audio/ogg", vorbisBOS),
            ("Vorbis MIME", "song.ogg", "audio/x-vorbis+ogg", validOggOpus),
            ("Speex in .ogg", "voice.ogg", "audio/ogg", speexBOS),
            ("Truncated Opus without OpusTags", "trunc.ogg", "audio/ogg", opusOnlyBOS),
            ("Dotfile with no stem", ".opus", "audio/opus", validOggOpus),
            ("Extensionless inside .opus dir", "/tmp/folder.opus/README", "audio/opus", validOggOpus),
            ("Standalone .flac", "track.flac", "audio/flac", rawFlacHeader),
            ("Standalone .flac x-flac", "track.flac", "audio/x-flac", rawFlacHeader),
            ("Native fLaC disguised as .ogg", "track.ogg", "audio/ogg", rawFlacHeader),
            ("Native fLaC disguised as .opus", "track.opus", "audio/opus", rawFlacHeader),
            ("Native fLaC disguised as .wav", "track.wav", "audio/wav", rawFlacHeader),
            ("FLAC-in-Ogg .oga", "track.oga", "audio/x-flac+ogg", oggFlacBOS),
            ("FLAC-in-Ogg .ogg audio/ogg", "track.ogg", "audio/ogg", oggFlacBOS),
            ("FLAC-in-Ogg .ogg application/ogg", "track.ogg", "application/ogg", oggFlacBOS),
        ]

        for (label, fileName, mime, bytes) in rejectedCases {
            let res = contract.validateCandidate(fileName: fileName, mimeType: mime, headerBytes: bytes)
            #expect(!res.accepted && res.typeID == nil, "Expected rejection for \(label), got \(res)")
        }

        // Verify file-level disguised container check used by desktop drag-and-drop hover
        let theoraFile = f.root.appendingPathComponent("disguised-theora.ogg")
        try theoraBOS.write(to: theoraFile)
        #expect(contract.isDisguisedUnsupportedContainer(at: theoraFile))

        let oggFlacFile = f.root.appendingPathComponent("disguised-flac.ogg")
        try oggFlacBOS.write(to: oggFlacFile)
        #expect(contract.isDisguisedUnsupportedContainer(at: oggFlacFile))

        let rawFlacInWav = f.root.appendingPathComponent("disguised-flac.wav")
        try rawFlacHeader.write(to: rawFlacInWav)
        #expect(contract.isDisguisedUnsupportedContainer(at: rawFlacInWav))
    }

    // MARK: - 3. Offline MP3, M4A, and WAV Import & Duplicate / Archive Handling

    @Test func mp3M4aAndWavDecodeOfflineIntoPortableReceivedMeetingsAndDeduplicate() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        let sourcesDir = f.root.appendingPathComponent("Incoming")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let wavURL = sourcesDir.appendingPathComponent("Team standup.wav")
        try Self.makeSyntheticWAV(to: wavURL, sampleRate: 44_100, channels: 2, frames: 26_460) // 600 ms

        let wavMono16URL = sourcesDir.appendingPathComponent("Voice memo 16k.wav")
        try Self.makeSyntheticWAV(to: wavMono16URL, sampleRate: 16_000, channels: 1, frames: 12_000, floatPCM: true) // 750 ms

        let m4aURL = sourcesDir.appendingPathComponent("Design critique.m4a")
        try Self.makeSyntheticM4A(to: m4aURL, sampleRate: 44_100, channels: 2, frames: 30_870) // 700 ms

        let m4aLosslessURL = sourcesDir.appendingPathComponent("Board briefing ALAC.m4a")
        try Self.makeSyntheticM4A(to: m4aLosslessURL, sampleRate: 48_000, channels: 1, frames: 24_000, losslessALAC: true) // 500 ms

        let mp3URL = sourcesDir.appendingPathComponent("Customer interview.mp3")
        try Self.makeSyntheticMP3(frameCount: 35, withID3v2: true).write(to: mp3URL)

        let candidates: [(URL, String)] = [
            (wavURL, "Team standup"),
            (wavMono16URL, "Voice memo 16k"),
            (m4aURL, "Design critique"),
            (m4aLosslessURL, "Board briefing ALAC"),
            (mp3URL, "Customer interview"),
        ]

        for (url, expectedTitle) in candidates {
            let sourceBytes = try Data(contentsOf: url)
            let expectedDigest = SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()

            let first = try LibraryImport.copyWithOutcome(url, into: library)
            guard case .imported(let meeting) = first else {
                Issue.record("Expected fresh import for \(url.lastPathComponent)")
                continue
            }
            #expect(meeting.title == expectedTitle)
            #expect(meeting.state.origin == .received)
            #expect(meeting.state.lifecycle == .saved)
            #expect(meeting.state.transcript == .none)
            #expect(meeting.state.audioAvailable == true)
            #expect(meeting.canWriteDown == true)
            #expect(!meeting.transcribedOnAnotherDevice)
            #expect(meeting.received?.originalName == "original.opus")
            #expect(meeting.received?.originalFolderName == "Incoming")
            #expect(meeting.received?.sha256 == expectedDigest)
            #expect((meeting.durationMs ?? 0) >= 400)

            let opusFile = meeting.folder.appendingPathComponent("original.opus")
            let opusData = try Data(contentsOf: opusFile)
            let parsed = try CassiniReader.read(opusData)
            #expect(parsed.state == .plainAudio)
            if case .success(let audioDigest)? = parsed.audioDigest {
                #expect(audioDigest.channels == 1)
                #expect(audioDigest.sampleCount > 0)
            } else {
                Issue.record("Expected verified OpusAudioDigest for \(url.lastPathComponent)")
            }

            // Re-importing the same file (even under a different filename) hits O(1) duplicate detection
            let renamed = f.root.appendingPathComponent("Copy of " + url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: renamed)
            let second = try LibraryImport.copyWithOutcome(renamed, into: library)
            guard case .duplicate(let dup) = second else {
                Issue.record("Expected duplicate on re-import of \(url.lastPathComponent)")
                continue
            }
            #expect(dup.id == meeting.id)
        }

        let scanned = try LibraryScanner(root: library).scan().meetings
        #expect(scanned.count == candidates.count)
    }

    @Test func corruptDisguisedAndCancelledDecodedImportsLeaveLibraryClean() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let validWav = f.root.appendingPathComponent("Valid.wav")
        try Self.makeSyntheticWAV(to: validWav, frames: 8_000)
        #expect(throws: CancellationError.self) {
            _ = try LibraryImport.copy(validWav, into: library, shouldCancel: { true })
        }

        let badFiles: [(String, Data)] = [
            ("corrupt.mp3", Data("not an mp3 stream".utf8)),
            ("corrupt.m4a", Data("not an m4a container".utf8)),
            ("corrupt.wav", Data("RIFF\u{10}\0\0\0WAVEfmt broken".utf8)),
            ("flac-disguised.wav", Data("fLaC".utf8) + Data(repeating: 0, count: 64)),
            ("flac-disguised.m4a", Data("fLaC".utf8) + Data(repeating: 0, count: 64)),
            ("flac.flac", Data("fLaC".utf8) + Data(repeating: 0, count: 64)),
            ("audio.oga", Self.oggPage(payload: Data([0x7F]) + Data("FLAC".utf8) + Data(repeating: 0, count: 38))),
            ("theora.ogg", Self.oggPage(payload: Data([0x80]) + Data("theora".utf8) + Data(repeating: 0, count: 35))),
            ("flac.ogg", Self.oggPage(payload: Data([0x7F]) + Data("FLAC".utf8) + Data(repeating: 0, count: 38))),
        ]
        for (name, payload) in badFiles {
            let url = f.root.appendingPathComponent(name)
            try payload.write(to: url)
            #expect(throws: (any Error).self, "Expected import error for \(name)") {
                _ = try LibraryImport.copy(url, into: library)
            }
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }

    @Test func zipAndBatchImportsSupportMp3M4aWavRejectOpenAndUnsupportedAndReportPerURLOutcomes() throws {
        let f = try Fixture()
        let library = f.root.appendingPathComponent("Library")

        let wavURL = f.root.appendingPathComponent("clip.wav")
        try Self.makeSyntheticWAV(to: wavURL, sampleRate: 16_000, channels: 1, frames: 8_000)
        let m4aURL = f.root.appendingPathComponent("memo.m4a")
        try Self.makeSyntheticM4A(to: m4aURL, sampleRate: 44_100, channels: 1, frames: 22_050)
        let mp3Bytes = Self.makeSyntheticMP3(frameCount: 25)
        let opusBytes = try Data(contentsOf: f.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/002-plain-audio.opus"))

        let zipData = Self.makeStoredZip([
            (name: "Meetings/Standup.wav", payload: try Data(contentsOf: wavURL)),
            (name: "Meetings/Memo.m4a", payload: try Data(contentsOf: m4aURL)),
            (name: "Meetings/Interview.mp3", payload: mp3Bytes),
            (name: "Meetings/Existing.opus", payload: opusBytes),
            (name: "Meetings/Lossless.flac", payload: Data("fLaC".utf8) + Data(repeating: 0, count: 40)),
            (name: "Meetings/OggAudio.oga", payload: opusBytes),
            (name: "Meetings/Video.ogv", payload: Data("OggS".utf8) + Data(repeating: 0, count: 40)),
            (name: "Meetings/Corrupt.mp3", payload: Data("corrupt-mp3".utf8)),
        ])
        let zipURL = f.root.appendingPathComponent("Bundle.zip")
        try zipData.write(to: zipURL)

        var zipSummary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(zipURL, into: library, summary: &zipSummary)
        #expect(zipSummary.imported == 4)
        #expect(zipSummary.unsupported == 3)
        #expect(zipSummary.failed == 1)
        #expect(zipSummary.duplicates == 0)

        var dupZipSummary = LibraryImportSummary()
        _ = try ZipArchiveImport.importArchive(zipURL, into: library, summary: &dupZipSummary)
        #expect(dupZipSummary.imported == 0)
        #expect(dupZipSummary.duplicates == 4)
        #expect(dupZipSummary.unsupported == 3)
        #expect(dupZipSummary.failed == 1)

        // Verify LibraryBatchImport per-URL settled callback for UI failed-card retention (W4.6)
        let batchLib = f.root.appendingPathComponent("BatchLibrary")
        let goodMp3 = f.root.appendingPathComponent("Good.mp3")
        try mp3Bytes.write(to: goodMp3)
        let badWav = f.root.appendingPathComponent("Broken.wav")
        try Data("RIFF\u{08}\0\0\0WAVEbad".utf8).write(to: badWav)
        let ignoredFlac = f.root.appendingPathComponent("Ignored.flac")
        try (Data("fLaC".utf8) + Data(repeating: 0, count: 32)).write(to: ignoredFlac)

        var settled: [String: String?] = [:]
        var batchSummary = LibraryImportSummary()
        _ = try LibraryBatchImport.importURLs(
            [goodMp3, badWav, ignoredFlac],
            into: batchLib,
            summary: &batchSummary,
            onURLSettled: { url, reason in
                settled[url.lastPathComponent] = reason
            }
        )
        #expect(batchSummary.imported == 1)
        #expect(batchSummary.failed == 1)
        #expect(batchSummary.unsupported == 1)
        #expect(settled["Good.mp3"] == .some(nil))
        #expect(settled["Ignored.flac"] == .some(nil))
        let brokenReason = try #require(settled["Broken.wav"] ?? nil)
        #expect(!brokenReason.isEmpty)
    }

    @Test func decodedAudioImportScalesLinearlyInThreadCPUTime() throws {
        func threadCPUNanos() -> UInt64 {
            clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        }

        let f = try Fixture()
        let library = f.root.appendingPathComponent("ScaleLibrary")
        let warmupWav = f.root.appendingPathComponent("Warmup.wav")
        try Self.makeSyntheticWAV(to: warmupWav, sampleRate: 16_000, channels: 1, frames: 16_000)
        _ = try LibraryImport.copyWithOutcome(warmupWav, into: library)

        let wavN = f.root.appendingPathComponent("ScaleN.wav")
        let wav2N = f.root.appendingPathComponent("Scale2N.wav")
        let framesN: AVAudioFrameCount = 16_000 * 30   // 30s
        let frames2N: AVAudioFrameCount = 16_000 * 60  // 60s
        try Self.makeSyntheticWAV(to: wavN, sampleRate: 16_000, channels: 2, frames: framesN)
        try Self.makeSyntheticWAV(to: wav2N, sampleRate: 16_000, channels: 2, frames: frames2N)

        let startN = threadCPUNanos()
        let outcomeN = try LibraryImport.copyWithOutcome(wavN, into: library)
        let cpuN = max(1, threadCPUNanos() - startN)

        let start2N = threadCPUNanos()
        let outcome2N = try LibraryImport.copyWithOutcome(wav2N, into: library)
        let cpu2N = max(1, threadCPUNanos() - start2N)

        guard case .imported(let meetingN) = outcomeN, case .imported(let meeting2N) = outcome2N else {
            Issue.record("Expected imported outcomes for N and 2N WAV inputs")
            return
        }
        #expect((29_980...30_040).contains(meetingN.durationMs ?? 0))
        #expect((59_980...60_040).contains(meeting2N.durationMs ?? 0))
        // Linear O(N) streaming decode+encode: 2N input should stay well below quadratic (<= 4x thread CPU).
        #expect(Double(cpu2N) <= Double(cpuN) * 4.0, "Expected linear thread CPU scaling: cpuN=\(cpuN)ns, cpu2N=\(cpu2N)ns")
    }
}
