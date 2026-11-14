import Foundation

/// Makes `wrangler dev` (and the Cloudflare Vite plugin) see the variables `redact run` injects.
///
/// Wrangler builds a worker's local secrets from `.dev.vars` if it exists; otherwise from `.env`
/// files, and from the process environment only when `CLOUDFLARE_INCLUDE_PROCESS_ENV=true`.
/// So without help, values from Redact never reach a worker, and `.dev.vars` can't be deleted.
public enum WranglerDevSecrets {
    public static let flag = "CLOUDFLARE_INCLUDE_PROCESS_ENV"
    static let configNames = ["wrangler.jsonc", "wrangler.json", "wrangler.toml"]

    public struct Plan: Equatable {
        /// Extra variables for the command.
        public var environment: [String: String] = [:]
        public var warning: String?
    }

    /// What to add for a command run in `cwd`, for the project at `projectRoot`.
    public static func plan(cwd: String, projectRoot: String?, injected: [String: String],
                            existing: [String: String] = ProcessInfo.processInfo.environment,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Plan {
        guard !injected.isEmpty, let folder = configFolder(cwd: cwd, projectRoot: projectRoot, fileExists: fileExists) else {
            return Plan()
        }
        let devVars = (folder as NSString).appendingPathComponent(".dev.vars")
        if fileExists(devVars) {
            let shown = (devVars as NSString).abbreviatingWithTildeInPath
            return Plan(warning: "Wrangler reads \(shown) and ignores the values from Redact. Delete it (Redact has its values) to use them.")
        }
        if existing[flag] != nil { return Plan() }   // the user decided
        return Plan(environment: [flag: "true"])
    }

    /// The nearest folder with a Wrangler config, from `cwd` up to the project root (or the project
    /// root itself when the command runs outside it, as with `-p`).
    static func configFolder(cwd: String, projectRoot: String?, fileExists: (String) -> Bool) -> String? {
        let root = projectRoot.map { ($0 as NSString).standardizingPath }
        var folder = (cwd as NSString).standardizingPath
        if let root, folder != root, !folder.hasPrefix(root + "/") { folder = root }
        while true {
            if configNames.contains(where: { fileExists((folder as NSString).appendingPathComponent($0)) }) { return folder }
            if folder == root || folder == "/" || root == nil { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }
}
