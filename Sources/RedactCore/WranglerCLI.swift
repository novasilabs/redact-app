import Foundation

/// Runs `wrangler` the way the user's terminal would.
///
/// GUI apps don't inherit the shell's PATH (Wrangler is often installed through nvm), so commands go
/// through the user's login shell. Arguments are passed as positional parameters, never interpolated.
public enum WranglerCLI {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
    }

    public static func run(_ arguments: [String], environment extra: [String: String] = [:], directory: String? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            process.executableURL = URL(fileURLWithPath: shell)
            // -l -i loads .zprofile and .zshrc (where nvm usually lives). "$@" keeps arguments intact.
            process.arguments = ["-l", "-i", "-c", "wrangler \"$@\"", "wrangler"] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["WRANGLER_SEND_METRICS"] = "false"
            environment["NO_COLOR"] = "1"
            environment["FORCE_COLOR"] = "0"
            environment.removeValue(forKey: "CLOUDFLARE_API_TOKEN") // would block profile commands
            for (key, value) in extra { environment[key] = value }
            process.environment = environment
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      output: Self.clean(String(decoding: data, as: UTF8.self))))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(status: -1, output: "Could not start shell: \(error)"))
            }
        }
    }

    /// Strips ANSI escapes and Wrangler's experimental-command banner.
    static func clean(_ text: String) -> String {
        let noANSI = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return noANSI.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("experimental command") && !$0.contains("⛅️") && !$0.hasPrefix("───") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Binds a profile to a directory, resolving symlinks first (Wrangler looks up the real cwd,
    /// so a binding stored under a symlinked path would never apply).
    public static func activate(profile: String, directory: String) async -> Result {
        await run(["auth", "activate", profile, WranglerProfiles.realPath(directory)])
    }

    public static func deactivate(directory: String) async -> Result {
        await run(["auth", "deactivate", WranglerProfiles.realPath(directory)])
    }

    /// Starts the browser OAuth flow for a new profile. Returns when the user finishes (or it fails).
    public static func createProfile(_ name: String) async -> Result {
        await run(["auth", "create", name])
    }

    /// `wrangler whoami --json` as seen from `directory` (whoami rejects `--profile`, so we rely on the
    /// directory binding instead).
    public static func whoami(in directory: String) async -> Result {
        await run(["whoami", "--json"], directory: directory)
    }

    /// Turns on Wrangler's keyring storage and migrates existing plaintext logins.
    ///
    /// `keyring enable` only affects new logins; Wrangler encrypts an old `<profile>.toml` (and deletes it)
    /// the next time it reads that profile. So each plaintext profile is read once with `auth token`, from
    /// a scratch folder where that profile is active. The token output is discarded, never shown.
    public static func moveTokensToKeychain(profiles: [String]) async -> Result {
        let enable = await run(["auth", "keyring", "enable"])
        guard enable.status == 0 else { return enable }
        var lines: [String] = []
        var failed = false
        for profile in profiles {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("redact-wrangler-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let dir = WranglerProfiles.realPath(scratch.path)
            if profile != "default" {
                let bound = await run(["auth", "activate", profile, dir])
                guard bound.status == 0 else { failed = true; lines.append("\(profile): couldn't select it (\(bound.output))"); continue }
            }
            let read = await run(["auth", "token"], directory: dir)
            if profile != "default" { _ = await run(["auth", "deactivate", dir]) }
            if read.status == 0 {
                lines.append("\(profile): moved to the Keychain.")
            } else {
                failed = true
                lines.append("\(profile): not moved. Log in again for this profile; new logins go to the Keychain.")
            }
        }
        return Result(status: failed ? 1 : 0, output: lines.isEmpty ? "Keychain storage is on." : lines.joined(separator: "\n"))
    }
}
