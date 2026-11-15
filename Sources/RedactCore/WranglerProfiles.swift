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
        #if REDACT_DEV
        // Screenshots and tests: a demo Wrangler folder, never the developer's real logins.
        if let demo = environment["REDACT_WRANGLER_HOME"], !demo.isEmpty { return URL(fileURLWithPath: demo, isDirectory: true) }
        #endif
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

/// Reads the account a Worker project pins in its Wrangler config (`account_id`).
public enum WranglerConfig {
    public struct Pin: Equatable, Sendable {
        public var accountID: String
        public var file: String
    }

    static let fileNames = ["wrangler.jsonc", "wrangler.json", "wrangler.toml"]

    /// Looks in `directory` and its ancestors (nearest config wins), like Wrangler does.
    public static func pinnedAccount(from directory: String, stopAt root: String = "/") -> Pin? {
        var dir = URL(fileURLWithPath: WranglerProfiles.realPath(directory), isDirectory: true)
        while true {
            for name in fileNames {
                let file = dir.appendingPathComponent(name)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                // A config file without account_id still stops the search: it is the project's config.
                return accountID(in: text, toml: name.hasSuffix(".toml")).map { Pin(accountID: $0, file: file.path) }
            }
            if dir.path == root || dir.path == "/" { return nil }
            dir.deleteLastPathComponent()
        }
    }

    /// Top-level `account_id` only (not inside `[env.x]` tables or nested objects).
    public static func accountID(in text: String, toml: Bool) -> String? {
        if toml {
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { return nil } // first table: top level is over
                guard line.hasPrefix("account_id") else { continue }
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                var value = parts[1].trimmingCharacters(in: .whitespaces)
                if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
            return nil
        }
        // JSON / JSONC: track brace depth, ignoring strings and comments.
        var depth = 0
        var i = text.startIndex
        var inString = false
        var stringStart = text.startIndex
        var lastKey: String?
        var expectValue = false
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if c == "\\" { i = text.index(after: i) }
                else if c == "\"" {
                    inString = false
                    let s = String(text[text.index(after: stringStart)..<i])
                    if expectValue {
                        if depth == 1 && lastKey == "account_id" { return s }
                        expectValue = false
                    } else {
                        lastKey = s
                    }
                }
            } else if c == "/" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "/" {
                while i < text.endIndex && text[i] != "\n" { i = text.index(after: i) }
                continue
            } else if c == "/" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "*" {
                if let end = text.range(of: "*/", range: i..<text.endIndex) { i = end.upperBound; continue }
                return nil
            } else if c == "\"" {
                inString = true
                stringStart = i
            } else if c == ":" {
                expectValue = true
            } else if c == "," {
                expectValue = false
            } else if c == "{" || c == "[" {
                depth += 1
                expectValue = false
            } else if c == "}" || c == "]" {
                depth -= 1
            }
            if i < text.endIndex { i = text.index(after: i) }
        }
        return nil
    }
}
