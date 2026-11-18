// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Private app-to-worker protocol for PCM windows. Each process owns one verified model.
public enum LiveWindowProtocol {
    public static let sampleLimit = 8 * 16_000
    public static let lineLimit = 700_000

    public struct Request: Codable, Sendable {
        public let id: UInt64
        public let pcm: Data

        public init(id: UInt64, samples: [Float]) throws {
            guard !samples.isEmpty, samples.count <= sampleLimit, samples.allSatisfy(\.isFinite) else {
                throw WhistleFailure.audio
            }
            self.id = id
            pcm = samples.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
        }

        public func samples() throws -> [Float] {
            guard !pcm.isEmpty, pcm.count <= sampleLimit * 4, pcm.count.isMultiple(of: 4) else {
                throw WhistleFailure.audio
            }
            let values = pcm.withUnsafeBytes { bytes in
                stride(from: 0, to: pcm.count, by: 4).map {
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                }
            }
            guard values.allSatisfy(\.isFinite) else { throw WhistleFailure.audio }
            return values
        }
    }

    public struct Response: Codable, Sendable {
        public let id: UInt64
        public let transcript: WhistleTranscript?
        public let failed: Bool
    }

    public static func serve(decode: ([Float]) throws -> WhistleTranscript) throws {
        let input = WhistleLineReader(fd: STDIN_FILENO, maximum: lineLimit)
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        while let line = try input.next() {
            let request = try decoder.decode(Request.self, from: line)
            let response: Response
            do {
                response = try Response(id: request.id, transcript: decode(request.samples()), failed: false)
            } catch {
                response = Response(id: request.id, transcript: nil, failed: true)
            }
            try WhistleIO.write(encoder.encode(response) + Data([10]), to: STDOUT_FILENO)
            if response.failed { return }
        }
    }
}
