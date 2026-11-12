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
