import CryptoKit
import Foundation
import LocalAuthentication

/// On-disk vault: one JSON file containing key wraps and individually sealed records.
///
/// ```
/// {
///   "format": 1,
///   "protectors": [ {"kind":"enclave", ...}, {"kind":"recovery", ...} ],
///   "records": [ {"id": "...", "type": "item", "version": 3, "sealed": "<base64 ChaChaPoly>"} ]
/// }
/// ```
/// Each record is sealed with the vault key; `id|type|version` is authenticated as associated data,
/// so records cannot be swapped or rolled back individually without detection of the mismatch.
public struct VaultFile: Codable, Sendable {
    public static let currentFormat = 1

    public struct Protector: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case enclave, recovery, software }
        public var kind: Kind
        /// For `.enclave`: the Secure Enclave key's opaque handle (useless on any other Mac).
        public var keyHandle: Data?
        public var wrapped: VaultKeyWrap.Wrapped?
        /// For `.recovery` / `.software`: vault key sealed with a key derived from the secret.
        public var sealed: Data?
        public var salt: Data?
        public var createdAt: Date
    }

    public struct Record: Codable, Sendable {
        public var id: UUID
        public var type: String
        public var version: Int
        public var sealed: Data
    }

    public var format: Int
    public var protectors: [Protector]
    public var records: [Record]

    public init(format: Int, protectors: [Protector], records: [Record]) {
        self.format = format
        self.protectors = protectors
        self.records = records
    }

    // MARK: - Reading and writing

    public static func load(from url: URL) throws -> VaultFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(VaultFile.self, from: Data(contentsOf: url))
        guard file.format == currentFormat else { throw VaultError.unsupportedFormat(file.format) }
        return file
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Records

    static func associatedData(_ id: UUID, _ type: String, _ version: Int) -> Data {
        Data("\(id.uuidString)|\(type)|\(version)".utf8)
    }

    public static func seal(_ data: VaultData, previous: VaultFile?, key: SymmetricKey) throws -> [Record] {
        let encoder = JSONEncoder() // default date strategy: exact, unlike ISO 8601
        var versions: [UUID: Int] = [:]
        for record in previous?.records ?? [] { versions[record.id] = record.version }

        func make<T: Encodable>(_ id: UUID, _ type: String, _ value: T) throws -> Record {
            let version = (versions[id] ?? 0) + 1
            let box = try ChaChaPoly.seal(encoder.encode(value), using: key,
                                          authenticating: associatedData(id, type, version))
            return Record(id: id, type: type, version: version, sealed: box.combined)
        }

        var records: [Record] = []
        records += try data.items.map { try make($0.id, "item", $0) }
        records += try data.projects.map { try make($0.id, "project", $0) }
        records += try data.identities.map { try make($0.id, "identity", $0) }
        // Activity is one record so the log does not create hundreds of entries.
        records.append(try make(Self.activityRecordID, "activity", data.activity))
        return records
    }

    static let activityRecordID = UUID(uuidString: "00000000-0000-0000-0000-00000000AC71")!

    public func open(key: SymmetricKey) throws -> VaultData {
        let decoder = JSONDecoder()
        var data = VaultData()
        for record in records {
            let box = try ChaChaPoly.SealedBox(combined: record.sealed)
            let plaintext: Data
            do {
                plaintext = try ChaChaPoly.open(box, using: key,
                                                authenticating: Self.associatedData(record.id, record.type, record.version))
            } catch {
                throw VaultError.corruptRecord(record.id)
            }
            switch record.type {
            case "item": data.items.append(try decoder.decode(Item.self, from: plaintext))
            case "project": data.projects.append(try decoder.decode(Project.self, from: plaintext))
            case "identity": data.identities.append(try decoder.decode(Identity.self, from: plaintext))
            case "activity": data.activity = try decoder.decode([ActivityEntry].self, from: plaintext)
            default: continue // newer record types are ignored by older builds
            }
        }
        return data
    }

    // MARK: - Key protectors

    public static func enclaveProtector(for vaultKey: SymmetricKey, requireBiometry: Bool) throws -> Protector {
        let enclaveKey = try VaultKeyWrap.makeEnclaveKey(requireBiometry: requireBiometry)
        let wrapped = try VaultKeyWrap.wrap(vaultKey: vaultKey, to: enclaveKey.publicKey)
        return Protector(kind: .enclave, keyHandle: enclaveKey.dataRepresentation, wrapped: wrapped,
                         sealed: nil, salt: nil, createdAt: Date())
    }

    /// Protector for a high-entropy secret (the Recovery Key, or a test key). No slow KDF is needed
    /// because the secret is 256 random bits, not a password.
    public static func secretProtector(for vaultKey: SymmetricKey, secret: Data, kind: Protector.Kind) throws -> Protector {
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let wrappingKey = deriveKey(secret: secret, salt: salt)
        let sealed = try ChaChaPoly.seal(vaultKey.withUnsafeBytes { Data($0) }, using: wrappingKey).combined
        return Protector(kind: kind, keyHandle: nil, wrapped: nil, sealed: sealed, salt: salt, createdAt: Date())
    }

    static func deriveKey(secret: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                               info: Data("redact.recovery.v1".utf8), outputByteCount: 32)
    }

    public func unlockWithEnclave(context: LAContext?) throws -> SymmetricKey {
        guard let protector = protectors.first(where: { $0.kind == .enclave }),
              let handle = protector.keyHandle, let wrapped = protector.wrapped else {
            throw VaultError.noProtector("enclave")
        }
        let key = try VaultKeyWrap.loadEnclaveKey(handle, context: context)
        return try VaultKeyWrap.unwrap(wrapped, with: key)
    }

    public func unlock(secret: Data, kind: Protector.Kind) throws -> SymmetricKey {
        for protector in protectors where protector.kind == kind {
            guard let sealed = protector.sealed, let salt = protector.salt else { continue }
            let key = Self.deriveKey(secret: secret, salt: salt)
            if let plaintext = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key) {
                return SymmetricKey(data: plaintext)
            }
        }
        throw VaultError.wrongRecoveryKey
    }
}

public enum VaultError: LocalizedError, Equatable {
    case unsupportedFormat(Int)
    case noProtector(String)
    case wrongRecoveryKey
    case corruptRecord(UUID)
    case locked
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let v): "This vault uses format \(v), which this version of Redact cannot read."
        case .noProtector(let kind): "The vault has no \(kind) key."
        case .wrongRecoveryKey: "That Recovery Key does not open this vault."
        case .corruptRecord(let id): "Record \(id) failed authentication. The vault file may be damaged or tampered with."
        case .locked: "The vault is locked."
        case .notFound: "No vault exists yet."
        }
    }
}

/// 256-bit Recovery Key, shown to the user as `XXXX-XXXX-…` (Crockford base32, 13 groups of 4).
public enum RecoveryKey {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    public static func format(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var output: [Character] = []
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: output.count, by: 4)
            .map { String(output[$0..<min($0 + 4, output.count)]) }
            .joined(separator: "-")
    }

    public static func parse(_ text: String) -> Data? {
        let cleaned = text.uppercased()
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .filter { $0 != "-" && !$0.isWhitespace }
        var bits = 0
        var value = 0
        var bytes: [UInt8] = []
        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            value &= (1 << bits) - 1
        }
        return bytes.count == 32 ? Data(bytes) : nil
    }
}
