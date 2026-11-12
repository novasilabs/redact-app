import Foundation
import Testing
@testable import RedactCore

@Test func parsesDotenvSyntax() {
    let text = """
    # comment
    PLAIN=value
    export EXPORTED=yes
    SPACED = trimmed  # trailing comment
    DOUBLE="has # hash and \\"quotes\\"\\nnewline"
    SINGLE='literal \\n stays'
    MULTI="line one
    line two"
    EMPTY=
    1BAD=no
    URL=postgres://u:p@host:5432/db?ssl=true
    """
    let entries = EnvFile.parse(text)
    let map = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.value) })
    #expect(map["PLAIN"] == "value")
    #expect(map["EXPORTED"] == "yes")
    #expect(map["SPACED"] == "trimmed")
    #expect(map["DOUBLE"] == "has # hash and \"quotes\"\nnewline")
    #expect(map["SINGLE"] == "literal \\n stays")
    #expect(map["MULTI"] == "line one\nline two")
    #expect(map["EMPTY"] == "")
    #expect(map["1BAD"] == nil)
    #expect(map["URL"] == "postgres://u:p@host:5432/db?ssl=true")
}

@Test func serializeRoundTrips() {
    let values = ["A": "plain", "B": "with \"quotes\" and \\ and\nnewline", "C": ""]
    let parsed = EnvFile.parse(EnvFile.serialize(values))
    #expect(Dictionary(uniqueKeysWithValues: parsed.map { ($0.name, $0.value) }) == values)
}

@Test func classifiesEnvFileNames() {
    #expect(ProjectScanner.classify(fileName: ".env")?.environment == "development")
    #expect(ProjectScanner.classify(fileName: ".env.local")?.environment == "development")
    #expect(ProjectScanner.classify(fileName: ".env.production.local")?.environment == "production")
    #expect(ProjectScanner.classify(fileName: ".env.staging")?.environment == "preview")
    #expect(ProjectScanner.classify(fileName: ".dev.vars")?.environment == "development")
    #expect(ProjectScanner.classify(fileName: ".env.example")?.isExample == true)
    #expect(ProjectScanner.classify(fileName: "env.ts") == nil)
    #expect(ProjectScanner.classify(fileName: ".dev.vars.example")?.isExample == true)
    #expect(ProjectScanner.classify(fileName: ".dev.vars.example")?.environment == nil)
    #expect(ProjectScanner.classify(fileName: ".dev.vars.production")?.environment == "production")
}

@Test func buildsImportPlanWithDiffLinksAndGaps() throws {
    let root = URL(fileURLWithPath: WranglerProfiles.realPath(NSTemporaryDirectory()))
        .appendingPathComponent("redact-import-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("apps/api"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
    try "OPENAI_API_KEY=sk-proj-shared123456\nPORT=3000\nDEBUG=1\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "DEBUG=0\n".write(to: root.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    try "PORT=8080\n".write(to: root.appendingPathComponent(".env.production"), atomically: true, encoding: .utf8)
    try "OPENAI_API_KEY=\nPORT=\nSENTRY_DSN=\n".write(to: root.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
    try "API_SECRET=apisecret999\n".write(to: root.appendingPathComponent("apps/api/.dev.vars"), atomically: true, encoding: .utf8)
    try "IGNORED=yes\n".write(to: root.appendingPathComponent("node_modules/pkg/.env"), atomically: true, encoding: .utf8)

    var vault = VaultData()
    let project = Project(name: "demo", path: root.path)
    vault.projects.append(project)
    let shared = Item(kind: .apiKey, name: "OpenAI personal", value: "sk-proj-shared123456")
    vault.items.append(shared)
    vault.items.append(Item(kind: .variable, name: "PORT", value: "3000", projectID: project.id, environment: "development"))

    let plan = try ImportPlan.build(root: root.path, project: project, vault: vault)
    #expect(!plan.rows.contains { $0.name == "IGNORED" })
    let dev = plan.rows.filter { $0.environment == "development" }
    #expect(dev.first { $0.name == "PORT" }?.status == .unchanged)
    #expect(dev.first { $0.name == "OPENAI_API_KEY" }?.duplicateOf == shared.id)
    #expect(dev.filter { $0.name == "DEBUG" }.map(\.shadowed) == [true, false])
    #expect(plan.rows.first { $0.environment == "production" && $0.name == "PORT" }?.status == .new)
    #expect(plan.missingFromExample["development"] == ["SENTRY_DSN"])

    // A nested folder that is its own project is not scanned into the parent.
    var withNested = vault
    withNested.projects.append(Project(name: "api", path: root.appendingPathComponent("apps/api").path))
    let parentOnly = try ImportPlan.build(root: root.path, project: project, vault: withNested)
    #expect(!parentOnly.rows.contains { $0.name == "API_SECRET" })

    plan.apply(to: &vault, project: project)
    let env = vault.environment(projectID: project.id, environment: "development")
    #expect(env["OPENAI_API_KEY"] == "sk-proj-shared123456")
    #expect(env["DEBUG"] == "0")
    #expect(env["API_SECRET"] == "apisecret999")
    #expect(vault.items.first { $0.name == "OPENAI_API_KEY" && $0.kind == .variable }?.linkedItemID == shared.id)
}

@Test func scanSkipsAgentWorktreesAndNestedCheckouts() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("redact-scan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    for dir in ["apps/web", ".claude/worktrees/planner", "vendored-repo"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try "A=1".write(to: root.appendingPathComponent(".dev.vars"), atomically: true, encoding: .utf8)
    try "B=2".write(to: root.appendingPathComponent("apps/web/.env.local"), atomically: true, encoding: .utf8)
    try "A=stale".write(to: root.appendingPathComponent(".claude/worktrees/planner/.dev.vars"), atomically: true, encoding: .utf8)
    try "gitdir: /elsewhere".write(to: root.appendingPathComponent("vendored-repo/.git"), atomically: true, encoding: .utf8)
    try "C=3".write(to: root.appendingPathComponent("vendored-repo/.env"), atomically: true, encoding: .utf8)

    let found = ProjectScanner.scan(root: root.path).map(\.relativePath).sorted()
    #expect(found == [".dev.vars", "apps/web/.env.local"])
}

@Test func onlySecretLikeVaultValuesAreScannedFor() {
    // Configuration, not secrets: finding these in code is expected.
    #expect(!SecretScanner.isSecretLike(name: "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", value: "sb_publishable_9f8e7d6c5b4a3f2e1d0c"))
    #expect(!SecretScanner.isSecretLike(name: "VITE_SITE_URL", value: "https://example.com"))
    #expect(!SecretScanner.isSecretLike(name: "SUPABASE_URL", value: "https://abcdefghijklmnop.supabase.co"))
    #expect(!SecretScanner.isSecretLike(name: "DOCUMENTS_BUCKET", value: "documents"))
    #expect(!SecretScanner.isSecretLike(name: "SERVICE_ACCOUNT_PATH", value: "./service-account.json"))
    #expect(!SecretScanner.isSecretLike(name: "EMAIL_FROM", value: "hello@example.com"))
    #expect(!SecretScanner.isSecretLike(name: "API_KEY", value: "abc"))
    // Secrets.
    #expect(SecretScanner.isSecretLike(name: "SUPABASE_SECRET_KEY", value: "sb_secret_Q2x7Vb9Lm4Kp8Rt1"))
    #expect(SecretScanner.isSecretLike(name: "DATABASE_URL", value: "postgres://app:s3cretPw@db.example.com:5432/app"))
    #expect(SecretScanner.isSecretLike(name: "WEBHOOK", value: "https://hooks.example.com/x?token=abc123def456"))
    #expect(SecretScanner.isSecretLike(name: "CRON_SECRET", value: "k7f2m9q4x1z8w3v6"))
}

@Test func scannerSkipsBuildOutput() {
    #expect(SecretScanner.skippedDirectories.contains(".open-next"))
    #expect(ProjectScanner.skippedDirectories.contains(".svelte-kit"))
}
