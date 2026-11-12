import CryptoKit
import Foundation
import LocalAuthentication
import RedactCore

// Usage:
//   spike-se roundtrip [--biometry] <dir>   create SE key, wrap a random vault key, unwrap it, compare
//   spike-se unwrap <dir>                   unwrap again using the stored files (new process)

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first, let dir = args.last, args.count >= 2 else {
    print("usage: spike-se roundtrip [--biometry] <dir> | spike-se unwrap <dir>")
    exit(64)
}
let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
let keyFile = dirURL.appendingPathComponent("enclave-key.bin")
let wrappedFile = dirURL.appendingPathComponent("wrapped.json")
let checkFile = dirURL.appendingPathComponent("vault-key.sha256")

print("SecureEnclave.isAvailable = \(SecureEnclave.isAvailable)")

func digest(_ key: SymmetricKey) -> String {
    key.withUnsafeBytes { SHA256.hash(data: Data($0)) }.map { String(format: "%02x", $0) }.joined()
}

func unwrapFromDisk() throws {
    let context = LAContext()
    context.localizedReason = "unlock the Redact spike vault"
    let start = Date()
    let key = try VaultKeyWrap.loadEnclaveKey(try Data(contentsOf: keyFile), context: context)
    let wrapped = try JSONDecoder().decode(VaultKeyWrap.Wrapped.self, from: Data(contentsOf: wrappedFile))
    let vaultKey = try VaultKeyWrap.unwrap(wrapped, with: key)
    let ms = Date().timeIntervalSince(start) * 1000
    let expected = try String(contentsOf: checkFile, encoding: .utf8)
    print(String(format: "unwrap ok=%@ in %.0f ms", digest(vaultKey) == expected ? "true" : "false", ms))
    // Second use with the same LAContext: should not prompt again.
    let again = Date()
    _ = try VaultKeyWrap.unwrap(wrapped, with: key)
    print(String(format: "second unwrap with same context in %.1f ms", Date().timeIntervalSince(again) * 1000))
}

do {
    switch mode {
    case "roundtrip":
        let biometry = args.contains("--biometry")
        let enclaveKey = try VaultKeyWrap.makeEnclaveKey(requireBiometry: biometry)
        try enclaveKey.dataRepresentation.write(to: keyFile)
        let vaultKey = SymmetricKey(size: .bits256)
        let wrapped = try VaultKeyWrap.wrap(vaultKey: vaultKey, to: enclaveKey.publicKey)
        try JSONEncoder().encode(wrapped).write(to: wrappedFile)
        try digest(vaultKey).write(to: checkFile, atomically: true, encoding: .utf8)
        print("created SE key (biometry=\(biometry)), blob=\(enclaveKey.dataRepresentation.count) bytes; wrapped vault key")
        try unwrapFromDisk()
    case "unwrap":
        try unwrapFromDisk()
    default:
        print("unknown mode \(mode)")
        exit(64)
    }
} catch {
    print("ERROR: \(error)")
    exit(1)
}
