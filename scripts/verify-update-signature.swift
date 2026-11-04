// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

// Public inputs only. No app launch, private seed, keychain or network access.
do {
    guard CommandLine.arguments.count == 4,
          let publicBytes = Data(base64Encoded:try String(contentsOfFile:CommandLine.arguments[1], encoding:.utf8)
            .trimmingCharacters(in:.whitespacesAndNewlines)),
          let signature = Data(base64Encoded:CommandLine.arguments[2]), signature.count == 64 else { exit(1) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation:publicBytes)
    let archive = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3]), options:.mappedIfSafe)
    guard key.isValidSignature(signature, for:archive) else { exit(1) }
} catch { exit(1) }
