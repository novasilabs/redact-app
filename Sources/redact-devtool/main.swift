import CryptoKit
import Foundation
import RedactCore

// Dev-only helper (not shipped in Redact.app): creates a test vault in $REDACT_HOME whose Secure
// Enclave key does NOT require Touch ID, so the app can be driven from scripts.
//   REDACT_HOME=/tmp/x redact-devtool make-vault [--sample <project-dir>]
// --sample fills the vault with fake keys, a project, backup codes, an identity and activity.

var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "make-vault" else {
    print("usage: REDACT_HOME=<dir> redact-devtool make-vault [--sample <project-dir>]")
    exit(64)
}
guard ProcessInfo.processInfo.environment["REDACT_HOME"] != nil else {
    print("Refusing to run without REDACT_HOME (would touch your real vault).")
    exit(1)
}

var data = VaultData()
if let index = args.firstIndex(of: "--sample"), index + 1 < args.count {
    let path = WranglerProfiles.realPath(args[index + 1])
    let project = Project(name: (path as NSString).lastPathComponent, path: path)
    let api = Project(name: "billing-worker", path: path + "/workers/billing")
    data.projects = [project, api]
    let openAI = Item(kind: .apiKey, name: "OpenAI (personal)", value: "sk-proj-FAKE000000000000000000", notes: "Rotate quarterly")
    let stripe = Item(kind: .apiKey, name: "Stripe live", value: "sk_live_FAKE0000000000000000", tags: ["stripe"])
    let cfToken = Item(kind: .apiKey, name: "Cloudflare token · acme-deploy", value: "FAKEcloudflareTOKEN000000000000000000000", tags: ["cloudflare", "identity"])
    data.items = [openAI, stripe, cfToken]
    for env in ["development", "production"] {
        data.items.append(Item(kind: .variable, name: "OPENAI_API_KEY", projectID: project.id, environment: env, linkedItemID: openAI.id))
        data.items.append(Item(kind: .variable, name: "DATABASE_URL", value: "postgres://app:FAKE@\(env).db.example.com/app", projectID: project.id, environment: env))
    }
    data.items.append(Item(kind: .variable, name: "PORT", value: "3000", projectID: project.id, environment: "development"))
    data.items.append(Item(kind: .variable, name: "ANTHROPIC_API_KEY", value: "sk-ant-api03-FAKEfakeFAKEfake0000000000", projectID: project.id, environment: "development"))
    data.items.append(Item(kind: .variable, name: "STRIPE_SECRET_KEY", projectID: api.id, environment: "production", linkedItemID: stripe.id))
    var codes = Item(kind: .backupCodes, name: "GitHub")
    codes.codes = (1...10).map { BackupCode(code: String(format: "%04x-%04x", $0 * 4099 % 65536, $0 * 7919 % 65536), usedAt: $0 <= 7 ? Date() : nil) }
    data.items.append(codes)
    var aws = Item(kind: .backupCodes, name: "AWS root")
    aws.codes = (1...8).map { BackupCode(code: String(format: "%06d", $0 * 104729 % 1_000_000)) }
    data.items.append(aws)
    let ghToken = Item(kind: .apiKey, name: "GitHub token · work", value: "ghp_FAKEworkTOKEN0000000000000000000000", tags: ["github", "identity"])
    data.items.append(ghToken)
    data.identities = [
        Identity(name: "acme-deploy", mode: .apiToken(itemID: cfToken.id, accountID: "0123456789abcdef0123456789abcdef"), boundPaths: [path + "/workers"]),
        Identity(provider: .github, name: "work", mode: .apiToken(itemID: ghToken.id, accountID: nil), boundPaths: [path]),
        Identity(provider: .aws, name: "acme-prod", mode: .awsProfile(name: "acme-prod"), boundPaths: [path + "/workers/billing"]),
    ]
    data.log(ActivityEntry(date: Date().addingTimeInterval(-3600), caller: "redact", agent: nil, command: "npm run dev", directory: path, variableNames: ["DATABASE_URL", "OPENAI_API_KEY", "PORT"], outcome: .autoApproved))
    data.log(ActivityEntry(date: Date().addingTimeInterval(-600), caller: "redact", agent: "Claude Code", command: "npm test", directory: path, variableNames: ["DATABASE_URL", "OPENAI_API_KEY", "PORT"], outcome: .approved))
    data.log(ActivityEntry(date: Date().addingTimeInterval(-300), caller: "redact", agent: "Claude Code", command: "npx wrangler deploy --env production", directory: path, variableNames: ["DATABASE_URL"], outcome: .denied))
    data.log(ActivityEntry(date: Date().addingTimeInterval(-60), caller: "redact", agent: "Cursor", command: "npm run test:e2e", directory: path, variableNames: ["DATABASE_URL"], outcome: .granted))
}

let vaultKey = SymmetricKey(size: .bits256)
let recovery = RecoveryKey.generate()
let file = VaultFile(
    format: VaultFile.currentFormat,
    protectors: [
        try VaultFile.enclaveProtector(for: vaultKey, requireBiometry: false),
        try VaultFile.secretProtector(for: vaultKey, secret: recovery, kind: .recovery),
    ],
    records: try VaultFile.seal(data, previous: nil, key: vaultKey)
)
try file.write(to: RedactPaths.vault)
print("Created test vault at \(RedactPaths.vault.path)")
print("Recovery key: \(RecoveryKey.format(recovery))")
