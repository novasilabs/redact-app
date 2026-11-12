import Foundation

/// Read-only view of Wrangler's auth profiles (wrangler >= 4.15x, `wrangler auth` experimental).
///
/// On-disk layout (verified against wrangler 4.151.3):
///   <configRoot>/config/<profile>.toml              plaintext OAuth (oauth_token, refresh_token, expiration_time, scopes)
///   <configRoot>/config/<profile>.enc               same, encrypted when `wrangler auth keyring` is on
///   <configRoot>/profiles/directory-bindings.json   { "<absolute dir>": "<profile>" }
/// where configRoot is `~/.wrangler` if that directory exists (legacy, wins), else
/// `$XDG_CONFIG_HOME/.wrangler`, else `~/Library/Preferences/.wrangler`.
///
/// Writes should go through `wrangler auth activate/deactivate` so we stay compatible; this type only reads.
public struct WranglerProfiles {
    public let configRoot: URL

    public init(configRoot: URL) {
        self.configRoot = configRoot
    }

    public static func defaultConfigRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let legacy = home.appendingPathComponent(".wrangler", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return legacy
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent(".wrangler", isDirectory: true)
        }
        return home.appendingPathComponent("Library/Preferences/.wrangler", isDirectory: true)
    }

    public struct Profile: Equatable {
        public var name: String
        public var encrypted: Bool
    }

    public func profiles() -> [Profile] {
        let dir = configRoot.appendingPathComponent("config", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var result: [String: Bool] = [:]
        for file in files {
            if file.hasSuffix(".toml") { result[String(file.dropLast(5)), default: false] = result[String(file.dropLast(5))] ?? false }
            if file.hasSuffix(".enc") { result[String(file.dropLast(4))] = true }
        }
        return result.map { Profile(name: $0.key, encrypted: $0.value) }.sorted { $0.name < $1.name }
    }

    public func bindings() -> [String: String] {
        let file = configRoot.appendingPathComponent("profiles/directory-bindings.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    /// Bindings whose stored path differs from its real path. Wrangler matches against the
    /// real cwd, so these never apply (e.g. activating `/tmp/x` stores `/tmp/x`, but cwd is `/private/tmp/x`).
    public func brokenBindings() -> [String] {
        bindings().keys.filter { Self.realPath($0) != $0 }.sorted()
    }

    /// Same algorithm as wrangler's `getProfileForDirectoryFromBindings`: longest bound ancestor wins.
    public func resolve(directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> (profile: String, source: String) {
        if let token = environment["CLOUDFLARE_API_TOKEN"], !token.isEmpty {
            return ("(CLOUDFLARE_API_TOKEN)", "environment variable overrides all profiles")
        }
        let dir = Self.realPath(directory)
        for (bound, profile) in bindings().sorted(by: { $0.key.count > $1.key.count }) {
            if dir == bound || dir.hasPrefix(bound + "/") {
                return (profile, dir == bound ? "bound here" : "inherited from \(bound)")
            }
        }
        return ("default", "default profile")
    }

    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
