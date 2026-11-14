import CryptoKit
import Foundation
import LocalAuthentication

/// Wraps a 256-bit vault key to a Secure Enclave P-256 key (ECIES: ephemeral ECDH + HKDF + ChaChaPoly).
///
/// The Secure Enclave private key never leaves the chip. Its opaque `dataRepresentation` can be
/// stored anywhere (it is useless on another Mac), so no Keychain entitlement is needed.
public enum VaultKeyWrap {
    public struct Wrapped: Codable, Sendable {
        public var ephemeralPublicKey: Data
        public var sealed: Data
    }

    static let info = Data("redact.vault-key.v1".utf8)

    public static func makeEnclaveKey(requireBiometry: Bool, unprotectedForDemoVault: Bool = false) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        // Always require the owner: Touch ID when the Mac has it, otherwise the Mac password. A key with
        // only `.privateKeyUsage` could be used by any process of this user that reads the vault file.
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        // Demo vaults (screenshots, devtool) hold fake data and must open without a prompt.
        if !unprotectedForDemoVault { flags.insert(requireBiometry ? .biometryCurrentSet : .userPresence) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
    }

    public static func loadEnclaveKey(_ data: Data, context: LAContext?) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data, authenticationContext: context)
    }

    public static func wrap(vaultKey: SymmetricKey, to recipient: P256.KeyAgreement.PublicKey) throws -> Wrapped {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let wrappingKey = derive(shared, ephemeral.publicKey, recipient)
        let plaintext = vaultKey.withUnsafeBytes { Data($0) }
        let box = try ChaChaPoly.seal(plaintext, using: wrappingKey)
        return Wrapped(ephemeralPublicKey: ephemeral.publicKey.x963Representation, sealed: box.combined)
    }

    public static func unwrap(_ wrapped: Wrapped, with key: SecureEnclave.P256.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: wrapped.ephemeralPublicKey)
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral)
        let wrappingKey = derive(shared, ephemeral, key.publicKey)
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: wrapped.sealed), using: wrappingKey)
        return SymmetricKey(data: plaintext)
    }

    private static func derive(_ shared: SharedSecret, _ ephemeral: P256.KeyAgreement.PublicKey, _ recipient: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.x963Representation + recipient.x963Representation,
            sharedInfo: info,
            outputByteCount: 32
        )
    }
}
