#!/usr/bin/env swift

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: sparkle-public-key.swift PRIVATE_KEY_FILE\n".utf8))
    exit(2)
}

let path = CommandLine.arguments[1]
let encoded = try String(contentsOfFile: path, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: encoded), seed.count == 32 else {
    FileHandle.standardError.write(Data(
        "Sparkle private key must be a base64-encoded 32-byte Ed25519 seed.\n".utf8
    ))
    exit(1)
}

let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(privateKey.publicKey.rawRepresentation.base64EncodedString())
