import Foundation
import Testing
@testable import RedactCore

private func fixture() throws -> (root: URL, projects: URL) {
    let base = URL(fileURLWithPath: WranglerProfiles.realPath(NSTemporaryDirectory()))
        .appendingPathComponent("redact-wrangler-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent(".wrangler", isDirectory: true)
    let projects = base.appendingPathComponent("projects", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("profiles"), withIntermediateDirectories: true)
    for dir in ["acme/api/src", "acme-old", "personal/blog"] {
        try fm.createDirectory(at: projects.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    // A symlinked path, like /tmp -> /private/tmp on macOS.
    try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: projects.appendingPathComponent("personal"))
    try Data().write(to: root.appendingPathComponent("config/default.toml"))
    try Data().write(to: root.appendingPathComponent("config/acme.toml"))
    try Data().write(to: root.appendingPathComponent("config/personal.enc"))
    let bindings = [
        projects.appendingPathComponent("acme").path: "acme",
        projects.appendingPathComponent("acme/api").path: "personal",
        projects.appendingPathComponent("personal").path: "personal",
        base.appendingPathComponent("link").path: "acme",
    ]
    try JSONSerialization.data(withJSONObject: bindings)
        .write(to: root.appendingPathComponent("profiles/directory-bindings.json"))
    return (root, projects)
}

@Test func listsProfilesIncludingEncrypted() throws {
    let (root, _) = try fixture()
    let names = WranglerProfiles(configRoot: root).profiles()
    #expect(names == [.init(name: "acme", encrypted: false), .init(name: "default", encrypted: false), .init(name: "personal", encrypted: true)])
}

@Test func resolvesNearestAncestorLikeWrangler() throws {
    let (root, projects) = try fixture()
    let store = WranglerProfiles(configRoot: root)
    let env: [String: String] = [:]
    #expect(store.resolve(directory: projects.appendingPathComponent("acme").path, environment: env).profile == "acme")
    #expect(store.resolve(directory: projects.appendingPathComponent("acme/api/src").path, environment: env).profile == "personal")
    // Prefix match must respect path boundaries: acme-old is not inside acme.
    #expect(store.resolve(directory: projects.appendingPathComponent("acme-old").path, environment: env).profile == "default")
    #expect(store.resolve(directory: projects.appendingPathComponent("personal/blog").path, environment: env).source.hasPrefix("inherited"))
}

@Test func apiTokenOverridesEverything() throws {
    let (root, projects) = try fixture()
    let result = WranglerProfiles(configRoot: root)
        .resolve(directory: projects.appendingPathComponent("acme").path, environment: ["CLOUDFLARE_API_TOKEN": "x"])
    #expect(result.profile == "(CLOUDFLARE_API_TOKEN)")
}

@Test func flagsBindingsThatCanNeverMatch() throws {
    let (root, _) = try fixture()
    let broken = WranglerProfiles(configRoot: root).brokenBindings()
    #expect(broken.count == 1)
    #expect(broken.first?.hasSuffix("/link") == true)
}

@Test func legacyDirectoryWinsOverXDG() throws {
    let (root, _) = try fixture()
    let home = root.deletingLastPathComponent()
    let resolved = WranglerProfiles.defaultConfigRoot(home: home, environment: ["XDG_CONFIG_HOME": "/somewhere/else"])
    #expect(resolved.standardizedFileURL == root.standardizedFileURL)
}

@Test func readsTopLevelAccountIDFromToml() {
    let toml = """
    name = "api"
    account_id = "abc123" # acme
    [env.staging]
    account_id = "zzz"
    """
    #expect(WranglerConfig.accountID(in: toml, toml: true) == "abc123")
    #expect(WranglerConfig.accountID(in: "name = \"x\"\n[env.prod]\naccount_id = \"zzz\"", toml: true) == nil)
}

@Test func readsTopLevelAccountIDFromJsonc() {
    let jsonc = """
    {
      // the worker
      "name": "api",
      /* "account_id": "commented" */
      "env": { "staging": { "account_id": "nested" } },
      "account_id": "def456",
    }
    """
    #expect(WranglerConfig.accountID(in: jsonc, toml: false) == "def456")
    #expect(WranglerConfig.accountID(in: "{ \"env\": { \"x\": { \"account_id\": \"n\" } } }", toml: false) == nil)
}

@Test func findsNearestConfigUpwards() throws {
    let base = URL(fileURLWithPath: WranglerProfiles.realPath(NSTemporaryDirectory())).appendingPathComponent("redact-cfg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
    try "account_id = \"top\"\n".write(to: base.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
    let pin = WranglerConfig.pinnedAccount(from: base.appendingPathComponent("src/deep").path)
    #expect(pin?.accountID == "top")
    #expect(pin?.file.hasSuffix("wrangler.toml") == true)
}
