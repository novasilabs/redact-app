import Foundation
import Testing
@testable import RedactCore

@Test func findsKnownFormatsWithoutVault() {
    let scanner = SecretScanner(secrets: [:])
    let text = """
    const gh = "ghp_\(String(repeating: "a", count: 36))";
    aws_access_key_id = AKIAABCDEFGHIJKLMNOP
    DATABASE_URL=postgres://app:hunter22@db.example.com:5432/app
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    nothing to see here: sk_test_123 is a test key and postgres://localhost/app has no password
    """
    let findings = scanner.scan(text: text, source: "app.ts")
    #expect(findings.map(\.name) == ["GitHub token", "AWS access key", "Database URL with password", "Private key"])
    #expect(findings.map(\.line) == [1, 2, 3, 4])
    #expect(findings.allSatisfy { !$0.preview.contains("hunter22") && !$0.preview.contains("AKIAABCD") })
}

@Test func findsVaultValuesByName() {
    let scanner = SecretScanner(secrets: ["INTERNAL_TOKEN": "tok_9f8e7d6c5b4a3210", "PORT": "3000"])
    let findings = scanner.scan(text: "a\nheaders: { auth: 'tok_9f8e7d6c5b4a3210' }\nport 3000", source: "x.js")
    #expect(findings.count == 1)
    #expect(findings[0].kind == .vaultValue)
    #expect(findings[0].name == "INTERNAL_TOKEN")
    #expect(findings[0].line == 2)
    #expect(findings[0].preview == "headers: { auth: '[redact:INTERNAL_TOKEN]' }")
}

@Test func vaultValueWinsOverFormatForSameSecret() {
    let key = "sk_live_" + String(repeating: "Z", count: 24)
    let findings = SecretScanner(secrets: ["STRIPE_SECRET_KEY": key]).scan(text: "key=\(key)", source: "f")
    #expect(findings.map(\.name) == ["STRIPE_SECRET_KEY"])
}

@Test func scansDirectoriesSkippingDependenciesAndBinaries() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("redact-scan-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
    try "k = 'AKIAABCDEFGHIJKLMNOP'\n".write(to: root.appendingPathComponent("src/config.py"), atomically: true, encoding: .utf8)
    try "k = 'AKIAABCDEFGHIJKLMNOP'\n".write(to: root.appendingPathComponent("node_modules/x/i.js"), atomically: true, encoding: .utf8)
    try Data([0x00, 0x41, 0x4B, 0x49, 0x41]).write(to: root.appendingPathComponent("src/blob.txt"))
    try "SECRET=AKIAABCDEFGHIJKLMNOP\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

    let all = SecretScanner(secrets: [:]).scan(path: root.path)
    #expect(Set(all.map { ($0.source as NSString).lastPathComponent }) == ["config.py", ".env"])
    let noEnv = SecretScanner(secrets: [:]).scan(path: root.path, includeEnvFiles: false)
    #expect(noEnv.map { ($0.source as NSString).lastPathComponent } == ["config.py"])
}

@Test func scansOnlyAddedLinesOfADiffWithRealLineNumbers() {
    let diff = """
    diff --git a/src/app.ts b/src/app.ts
    --- a/src/app.ts
    +++ b/src/app.ts
    @@ -10,0 +11,2 @@
    +const ok = 1;
    +const key = "AKIAABCDEFGHIJKLMNOP";
    @@ -40 +42 @@
    -const old = "AKIAZZZZZZZZZZZZZZZZ";
    +const fine = true;
    """
    let findings = HealthScan.scanDiff(diff, scanner: SecretScanner(secrets: [:]), fallbackSource: "staged")
    #expect(findings.count == 1)
    #expect(findings[0].source == "src/app.ts")
    #expect(findings[0].line == 12)
}

@Test func scansGitHistoryForRemovedSecrets() throws {
    let repo = URL(fileURLWithPath: WranglerProfiles.realPath(NSTemporaryDirectory())).appendingPathComponent("redact-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    func git(_ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo.path, "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }
    try git("init", "-q")
    try "token = 'my-internal-token-123456'\n".write(to: repo.appendingPathComponent("config.py"), atomically: true, encoding: .utf8)
    try git("add", ".")
    try git("commit", "-qm", "add config")
    try "token = os.environ['TOKEN']\n".write(to: repo.appendingPathComponent("config.py"), atomically: true, encoding: .utf8)
    try git("commit", "-qam", "remove secret")

    let options = ScanOptions(paths: [repo.path], gitHistory: true)
    let findings = HealthScan.run(options, secrets: ["TOKEN": "my-internal-token-123456"])
    // Not in the working tree any more, but still in history.
    #expect(findings.count == 1)
    #expect(findings[0].name == "TOKEN")
    #expect(findings[0].source.hasPrefix("git "))
    #expect(findings[0].source.hasSuffix("config.py"))
}

@Test func nestedPathsAreScannedOnce() {
    #expect(HealthScan.outermost(["/a/b", "/a", "/a/b/c", "/x", "/ab"]) == ["/a", "/ab", "/x"])
}

@Test func databaseURLsToLocalHostsOrWithPlaceholdersAreNotLeaks() {
    let scanner = SecretScanner(secrets: [:])
    func hits(_ line: String) -> Int { scanner.scan(text: line, source: "x").count }
    #expect(hits("DATABASE_URL=postgres://postgres:postgres@127.0.0.1:54322/postgres") == 0)
    #expect(hits("url: postgresql://app:Sup3rS3cret@localhost:5432/app") == 0)
    #expect(hits("postgresql://postgres:[YOUR-PASSWORD]@db.abc.supabase.co:5432/postgres") == 0)
    #expect(hits("postgres://app:${DB_PASSWORD}@db.example.com/app") == 0)
    #expect(hits("postgres://app:Sup3rS3cret@db.example.com:5432/app") == 1)
}

@Test func privateKeyHeadersNeedKeyMaterial() {
    let scanner = SecretScanner(secrets: [:])
    let body = String(repeating: "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC", count: 3)
    #expect(scanner.scan(text: #".replace(/-----BEGIN PRIVATE KEY-----/g, "")"#, source: "x").isEmpty)
    #expect(scanner.scan(text: "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----", source: "x").isEmpty)
    #expect(scanner.scan(text: "-----BEGIN PRIVATE KEY-----\n\(body)\n-----END PRIVATE KEY-----", source: "x").count == 1)
    #expect(scanner.scan(text: #"{"private_key": "-----BEGIN PRIVATE KEY-----\n"# + body + #"\n-----END PRIVATE KEY-----\n"}"#, source: "x").count == 1)
}

@Test func firebaseClientConfigKeysAreNotLeaks() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("redact-fb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let line = #"{ "current_key": "AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q" }"#
    try line.write(to: dir.appendingPathComponent("google-services.json"), atomically: true, encoding: .utf8)
    try line.write(to: dir.appendingPathComponent("config.ts"), atomically: true, encoding: .utf8)
    let scanner = SecretScanner(secrets: [:])
    #expect(scanner.scanFile(dir.appendingPathComponent("google-services.json").path).isEmpty)
    #expect(scanner.scanFile(dir.appendingPathComponent("config.ts").path).count == 1)
}
