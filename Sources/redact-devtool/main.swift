import CryptoKit
import Foundation
import RedactCore

// Dev-only helper (not shipped in Redact.app): creates a test vault in $REDACT_HOME whose Secure
// Enclave key does NOT require Touch ID, so the app can be driven from scripts.
//   REDACT_HOME=/tmp/x redact-devtool make-vault

guard CommandLine.arguments.dropFirst().first == "make-vault" else {
    print("usage: REDACT_HOME=<dir> redact-devtool make-vault")
    exit(64)
}
guard ProcessInfo.processInfo.environment["REDACT_HOME"] != nil else {
    print("Refusing to run without REDACT_HOME (would touch your real vault).")
    exit(1)
}
let vaultKey = SymmetricKey(size: .bits256)
let recovery = RecoveryKey.generate()
let file = VaultFile(
    format: VaultFile.currentFormat,
    protectors: [
        try VaultFile.enclaveProtector(for: vaultKey, requireBiometry: false),
        try VaultFile.secretProtector(for: vaultKey, secret: recovery, kind: .recovery),
    ],
    records: try VaultFile.seal(VaultData(), previous: nil, key: vaultKey)
)
try file.write(to: RedactPaths.vault)
print("Created test vault at \(RedactPaths.vault.path)")
print("Recovery key: \(RecoveryKey.format(recovery))")
