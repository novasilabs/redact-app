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

    plan.apply(to: &vault, project: project)
    let env = vault.environment(projectID: project.id, environment: "development")
    #expect(env["OPENAI_API_KEY"] == "sk-proj-shared123456")
    #expect(env["DEBUG"] == "0")
    #expect(env["API_SECRET"] == "apisecret999")
    #expect(vault.items.first { $0.name == "OPENAI_API_KEY" && $0.kind == .variable }?.linkedItemID == shared.id)
}
