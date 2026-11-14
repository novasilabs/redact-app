import Testing
@testable import RedactCore

@Test func wranglerProjectsGetTheProcessEnvFlag() {
    let files: Set<String> = ["/r/app/wrangler.jsonc", "/r/legacy/wrangler.toml", "/r/legacy/.dev.vars"]
    func plan(_ cwd: String, root: String?, existing: [String: String] = [:], injected: [String: String] = ["A": "1"]) -> WranglerDevSecrets.Plan {
        WranglerDevSecrets.plan(cwd: cwd, projectRoot: root, injected: injected, existing: existing, fileExists: files.contains)
    }
    #expect(plan("/r/app", root: "/r/app").environment == ["CLOUDFLARE_INCLUDE_PROCESS_ENV": "true"])
    #expect(plan("/r/app/src/routes", root: "/r/app").environment["CLOUDFLARE_INCLUDE_PROCESS_ENV"] == "true")
    #expect(plan("/r", root: "/r/app").environment["CLOUDFLARE_INCLUDE_PROCESS_ENV"] == "true")   // -p from the repo root
    #expect(plan("/r/web", root: "/r/web") == .init())                                             // not a worker
    #expect(plan("/r/app", root: "/r/app", existing: ["CLOUDFLARE_INCLUDE_PROCESS_ENV": "false"]) == .init())
    #expect(plan("/r/app", root: "/r/app", injected: [:]) == .init())
    let legacy = plan("/r/legacy", root: "/r/legacy")
    #expect(legacy.environment.isEmpty)
    #expect(legacy.warning?.contains(".dev.vars") == true)
}
