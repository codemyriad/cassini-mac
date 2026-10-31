// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Display-only punctuation, scoped to one turn. Piece boundaries (and the
/// corresponding word times/identities) survive; stored transcript text does not change.
public enum TranscriptText {
    public static func quotes(_ pieces: [String]) -> [String] {
        let count = pieces.reduce(0) { $0 + $1.filter { $0 == "\"" }.count }
        let paired = count - count % 2
        var index = 0
        return pieces.map { piece in
            var result = ""
            for character in piece {
                guard character == "\"" else { result.append(character); continue }
                if index < paired { result.append(index.isMultiple(of:2) ? "“" : "”") }
                index += 1
            }
            return result
        }
    }
}
