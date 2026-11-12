import CryptoKit
import Foundation
import Testing
@testable import RedactCore

private func tempURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("redact-test-\(UUID().uuidString)/\(name)")
}

@Test func recoveryKeyRoundTrips() {
    for _ in 0..<50 {
        let key = RecoveryKey.generate()
        let text = RecoveryKey.format(key)
        #expect(text.split(separator: "-").count == 13)
        #expect(RecoveryKey.parse(text) == key)
        #expect(RecoveryKey.parse(text.lowercased().replacingOccurrences(of: "-", with: " ")) == key)
    }
    #expect(RecoveryKey.parse("not-a-key") == nil)
}

@Test func vaultSealsAndOpensRecords() throws {
    let url = tempURL("vault.redact")
    let vaultKey = SymmetricKey(size: .bits256)
    let recovery = RecoveryKey.generate()
    var data = VaultData()
    let project = Project(name: "acme", path: "/tmp/acme")
    data.projects.append(project)
    let shared = Item(kind: .apiKey, name: "OPENAI_API_KEY", value: "sk-proj-abcdef123456")
    data.items.append(shared)
    data.items.append(Item(kind: .variable, name: "OPENAI_API_KEY", projectID: project.id, environment: "development", linkedItemID: shared.id))
    data.items.append(Item(kind: .variable, name: "PORT", value: "3000", projectID: project.id, environment: "development"))

    let file = VaultFile(format: 1,
                         protectors: [try VaultFile.secretProtector(for: vaultKey, secret: recovery, kind: .recovery)],
                         records: try VaultFile.seal(data, previous: nil, key: vaultKey))
    try file.write(to: url)

    let raw = try String(contentsOf: url, encoding: .utf8)
    #expect(!raw.contains("sk-proj-abcdef123456"))
    #expect(!raw.contains("OPENAI_API_KEY"))

    let loaded = try VaultFile.load(from: url)
    let key = try loaded.unlock(secret: recovery, kind: .recovery)
    let opened = try loaded.open(key: key)
    #expect(opened == data)
    #expect(opened.environment(projectID: project.id, environment: "development") == ["OPENAI_API_KEY": "sk-proj-abcdef123456", "PORT": "3000"])
    #expect(throws: VaultError.wrongRecoveryKey) { try loaded.unlock(secret: RecoveryKey.generate(), kind: .recovery) }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
}

@Test func tamperedRecordIsRejected() throws {
    let vaultKey = SymmetricKey(size: .bits256)
    var data = VaultData()
    data.items.append(Item(kind: .apiKey, name: "A", value: "value-aaaaaa"))
    var file = VaultFile(format: 1, protectors: [], records: try VaultFile.seal(data, previous: nil, key: vaultKey))
    // Bump the version without re-sealing: associated data no longer matches.
    file.records[0].version += 1
    #expect(throws: VaultError.self) { try file.open(key: vaultKey) }
}

@Test func versionsIncrementOnReseal() throws {
    let vaultKey = SymmetricKey(size: .bits256)
    var data = VaultData()
    data.items.append(Item(kind: .apiKey, name: "A", value: "value-aaaaaa"))
    let first = VaultFile(format: 1, protectors: [], records: try VaultFile.seal(data, previous: nil, key: vaultKey))
    let second = try VaultFile.seal(data, previous: first, key: vaultKey)
    #expect(second.first { $0.id == data.items[0].id }?.version == 2)
}

@Test func projectLookupUsesNearestAncestor() {
    var data = VaultData()
    data.projects = [Project(name: "mono", path: "/work/mono"), Project(name: "api", path: "/work/mono/apps/api")]
    #expect(data.project(containing: "/work/mono/apps/api/src")?.name == "api")
    #expect(data.project(containing: "/work/mono/apps/web")?.name == "mono")
    #expect(data.project(containing: "/work/mono-old") == nil)
}

@Test func secretDetectorRecognizesCommonFormats() {
    #expect(SecretDetector.guess("sk_live_51Habc")?.suggestedName == "STRIPE_SECRET_KEY")
    #expect(SecretDetector.guess("sk-ant-api03-xyz")?.provider == "Anthropic")
    #expect(SecretDetector.guess("ghp_abcdefghijklmnop")?.provider == "GitHub")
    #expect(SecretDetector.guess("MY_TOKEN=abc123")?.suggestedName == "MY_TOKEN")
    #expect(SecretDetector.guess("1111-2222\n3333-4444\n5555-6666\n7777-8888")?.kind == .backupCodes)
    #expect(SecretDetector.guess("hello world") == nil)
}
