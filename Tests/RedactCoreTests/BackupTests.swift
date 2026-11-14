import CryptoKit
import Foundation
import Testing
@testable import RedactCore

/// A small vault: two projects, a shared key linked from one of them, backup codes, a GitHub account.
private struct Fixture {
    var data = VaultData()
    let acme = Project(name: "acme", path: "/Users/olduser/code/acme")
    let blog = Project(name: "blog", path: "/Users/olduser/code/blog")
    let stripe = Item(kind: .apiKey, name: "Stripe live", value: "sk_live_shared_value_123")
    let codes: Item
    let ghToken = Item(kind: .apiKey, name: "GitHub token · work", value: "ghp_token_value_456", tags: ["github", "identity"])
    let github: Identity

    init() {
        var codes = Item(kind: .backupCodes, name: "GitHub")
        codes.codes = ["1111-2222", "3333-4444"].map { BackupCode(code: $0) }
        self.codes = codes
        github = Identity(provider: .github, name: "work", mode: .apiToken(itemID: ghToken.id, accountID: nil),
                          boundPaths: ["/Users/olduser/code/acme"])
        data.projects = [acme, blog]
        data.items = [
            stripe, codes, ghToken,
            Item(kind: .variable, name: "STRIPE_SECRET_KEY", projectID: acme.id, environment: "production", linkedItemID: stripe.id),
            Item(kind: .variable, name: "DATABASE_URL", value: "postgres://acme", projectID: acme.id, environment: "development"),
            Item(kind: .variable, name: "BLOG_TOKEN", value: "blog-secret-value", projectID: blog.id, environment: "development"),
        ]
        data.identities = [github]
        data.log(ActivityEntry(date: Date(), caller: "redact", agent: nil, command: "npm test", directory: acme.path,
                               variableNames: ["DATABASE_URL"], outcome: .autoApproved))
    }
}

private func vault(_ data: VaultData, key: SymmetricKey, recovery: Data) throws -> VaultFile {
    VaultFile(format: VaultFile.currentFormat,
              protectors: [try VaultFile.secretProtector(for: key, secret: recovery, kind: .recovery)],
              records: try VaultFile.seal(data, previous: nil, key: key))
}

@Test func partialSelectionBringsItsDependencies() {
    let f = Fixture()
    let subset = f.data.subset(BackupSelection(projectIDs: [f.acme.id], identityIDs: [f.github.id]))
    #expect(subset.projects.map(\.name) == ["acme"])
    let names = Set(subset.items.map(\.name))
    #expect(names == ["STRIPE_SECRET_KEY", "DATABASE_URL", "Stripe live", "GitHub token · work"])
    #expect(!names.contains("BLOG_TOKEN"))
    #expect(!names.contains("GitHub"))           // backup codes weren't picked
    #expect(subset.activity.isEmpty)
    #expect(subset.resolvedValue(of: subset.items.first { $0.name == "STRIPE_SECRET_KEY" }!) == "sk_live_shared_value_123")
}

@Test func backupOpensWithRecoveryKeyAndCarriesNoTouchIDProtector() throws {
    let f = Fixture()
    let key = SymmetricKey(size: .bits256)
    let recovery = RecoveryKey.generate()
    var source = try vault(f.data, key: key, recovery: recovery)
    // Pretend this Mac also has a Touch ID protector: it must not travel.
    source.protectors.append(VaultFile.Protector(kind: .enclave, keyHandle: Data([1, 2, 3]), wrapped: nil, sealed: nil, salt: nil, createdAt: Date()))

    let backup = try VaultBackup.make(from: source, data: f.data, key: key, selection: .all(f.data))
    #expect(backup.protectors.allSatisfy { $0.kind == .recovery })
    #expect(backup.backup?.partial == false)
    #expect(backup.backup?.projects == 2)

    // Survives a write and a read, and nothing readable is in the file.
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("redact-backup-\(UUID().uuidString).redact")
    try backup.write(to: url)
    let raw = try String(contentsOf: url, encoding: .utf8)
    #expect(!raw.contains("sk_live_shared_value_123"))
    #expect(!raw.contains("STRIPE_SECRET_KEY"))
    let loaded = try VaultFile.load(from: url)
    #expect(loaded.backup?.projects == 2)

    let opened = try VaultBackup.open(loaded, recoveryKey: recovery)
    #expect(opened.data == f.data)
    #expect(throws: VaultError.wrongRecoveryKey) { try VaultBackup.open(loaded, recoveryKey: RecoveryKey.generate()) }
}

@Test func partialBackupIsMarkedPartial() throws {
    let f = Fixture()
    let key = SymmetricKey(size: .bits256)
    let source = try vault(f.data, key: key, recovery: RecoveryKey.generate())
    let backup = try VaultBackup.make(from: source, data: f.data, key: key, selection: BackupSelection(itemIDs: [f.codes.id]))
    #expect(backup.backup?.partial == true)
    #expect(backup.backup?.codeSets == 1)
    #expect(backup.backup?.projects == 0)
}

@Test func adoptMakesANewMacVaultThatStillOpensWithTheRecoveryKey() throws {
    let f = Fixture()
    let key = SymmetricKey(size: .bits256)
    let recovery = RecoveryKey.generate()
    let backup = try VaultBackup.make(from: try vault(f.data, key: key, recovery: recovery), data: f.data, key: key, selection: .all(f.data))
    let opened = try VaultBackup.open(backup, recoveryKey: recovery)
    let adopted = try VaultBackup.adopt(backup, data: opened.data, key: opened.key, enclave: nil)
    #expect(adopted.backup == nil)                 // a live vault, not a backup
    #expect(try adopted.open(key: try adopted.unlock(secret: recovery, kind: .recovery)) == f.data)
}

@Test func restorePlanSortsNewChangedAndSame() {
    let f = Fixture()
    var current = f.data
    // Changed: the blog token has a new value here. Same: acme, the Stripe key, the codes. New: a key only in the backup.
    let blogVar = current.items.firstIndex { $0.name == "BLOG_TOKEN" }!
    current.items[blogVar].value = "rotated-blog-value"
    var backup = f.data
    let extra = Item(kind: .apiKey, name: "Resend", value: "re_backup_only_key")
    backup.items.append(extra)

    let plan = RestorePlan(backup: backup, current: current)
    func status(_ name: String) -> RestorePlan.Status? { plan.rows.first { $0.name == name }?.status }
    #expect(status("acme") == .same)
    #expect(status("blog") == .changed)
    #expect(status("Resend") == .new)
    #expect(status("Stripe live") == .same)
    #expect(status("work") == .same)
    #expect(plan.rows.contains { $0.name == "GitHub token · work" } == false)   // tokens ride with their account
    #expect(plan.rows.filter(\.selected).map(\.name).sorted() == ["Resend", "blog"])
}

@Test func applyingAPlanRestoresIntoAnotherVaultWithRemappedPaths() {
    let f = Fixture()
    // The new Mac already has its own, unrelated vault.
    var current = VaultData()
    current.items = [Item(kind: .apiKey, name: "Mine", value: "mine-value-0000")]

    var plan = RestorePlan(backup: f.data, current: current)
    for i in plan.rows.indices { plan.rows[i].selected = plan.rows[i].name != "blog" }   // everything except blog
    let remap = PathRemap(from: "/Users/olduser", to: "/Users/newuser")
    plan.apply(to: &current, remap: remap.apply)

    #expect(current.items.contains { $0.name == "Mine" })
    #expect(current.projects.map(\.name) == ["acme"])
    #expect(current.projects[0].path == "/Users/newuser/code/acme")
    let acmeEnv = current.environment(projectID: f.acme.id, environment: "production")
    #expect(acmeEnv["STRIPE_SECRET_KEY"] == "sk_live_shared_value_123")    // linked key came along
    #expect(!current.items.contains { $0.name == "BLOG_TOKEN" })
    #expect(current.identities.first?.boundPaths == ["/Users/newuser/code/acme"])
    #expect(current.identityEnvironment(for: "/Users/newuser/code/acme/src").values["GH_TOKEN"] == "ghp_token_value_456")
    #expect(current.activity.count == 1)
}

@Test func restoringAProjectMatchedByPathKeepsTheExistingProjectID() {
    let f = Fixture()
    var current = VaultData()
    let local = Project(name: "acme", path: f.acme.path)          // same folder, different ID
    current.projects = [local]
    current.items = [Item(kind: .variable, name: "DATABASE_URL", value: "postgres://old", projectID: local.id, environment: "development")]

    var plan = RestorePlan(backup: f.data, current: current)
    #expect(plan.rows.first { $0.name == "acme" }?.status == .changed)
    for i in plan.rows.indices { plan.rows[i].selected = plan.rows[i].name == "acme" }
    plan.apply(to: &current)

    #expect(current.projects.count == 1)
    #expect(current.projects[0].id == local.id)
    let dev = current.items.filter { $0.projectID == local.id && $0.environment == "development" }
    #expect(dev.count == 1)                                          // replaced, not duplicated
    #expect(dev.first?.value == "postgres://acme")
}

@Test func pathRemapSuggestsTheNewHomeOnlyWhenPathsAreMissing() {
    let paths = ["/Users/olduser/code/acme", "/Users/olduser/code/blog", "/opt/shared"]
    let suggestion = PathRemap.suggest(for: paths, home: "/Users/newuser", exists: { _ in false })
    #expect(suggestion == PathRemap(from: "/Users/olduser", to: "/Users/newuser"))
    #expect(suggestion?.apply("/Users/olduser/code/acme") == "/Users/newuser/code/acme")
    #expect(suggestion?.apply("/Users/olduser-other/x") == "/Users/olduser-other/x")
    #expect(suggestion?.apply("/opt/shared") == "/opt/shared")
    #expect(PathRemap.suggest(for: paths, home: "/Users/olduser", exists: { _ in false }) == nil)     // same user
    #expect(PathRemap.suggest(for: paths, home: "/Users/newuser", exists: { _ in true }) == nil)      // folders are there
    #expect(PathRemap.missing(in: paths, remap: suggestion, exists: { $0.hasPrefix("/Users/newuser/code/acme") }) == ["/Users/newuser/code/blog", "/opt/shared"])
}

@Test func rotatingRetiresTheOldRecoveryKeyAndVaultKey() throws {
    let f = Fixture()
    let oldKey = SymmetricKey(size: .bits256)
    let old = RecoveryKey.generate()
    let oldFile = try vault(f.data, key: oldKey, recovery: old)
    let oldBackup = try VaultBackup.make(from: oldFile, data: f.data, key: oldKey, selection: .all(f.data))

    let new = RecoveryKey.generate()
    let rotated = try VaultFile.rotated(f.data, recoverySecret: new) { _ in [] }
    #expect(rotated.file.protectors.map(\.kind) == [.recovery])
    #expect(try rotated.file.open(key: try rotated.file.unlock(secret: new, kind: .recovery)) == f.data)
    #expect(throws: VaultError.wrongRecoveryKey) { try rotated.file.unlock(secret: old, kind: .recovery) }
    // The old vault key (recoverable from an old copy with the old Recovery Key) opens nothing new.
    #expect(throws: (any Error).self) { try rotated.file.open(key: oldKey) }

    #expect(throws: VaultError.wrongRecoveryKey) { try VaultBackup.open(oldBackup, recoveryKey: new) }
    let newBackup = try VaultBackup.make(from: rotated.file, data: f.data, key: rotated.key, selection: .all(f.data))
    #expect(try VaultBackup.open(newBackup, recoveryKey: new).data == f.data)
}
