// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

// No contents printed, including on failure. Read only the explicitly supplied
// private seed and public app key; never generate or overwrite a production key.
do {
    let seedText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let expected = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: seedText.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32 else { exit(1) }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    guard key.publicKey.rawRepresentation.base64EncodedString() == expected else { exit(1) }
} catch { exit(1) }
