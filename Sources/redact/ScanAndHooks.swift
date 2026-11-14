import Darwin
import Foundation
import RedactCore

// MARK: - redact scan

enum ScanCommand {
    static func run(_ arguments: [String], cwd: String) -> Never {
        var args = arguments
        let staged = takeFlag("--staged", from: &args)
        let all = takeFlag("--all", from: &args)
        let history = takeFlag("--history", from: &args) || all
        let shell = takeFlag("--shell", from: &args) || all
        let ai = takeFlag("--ai", from: &args) || all
        let includeEnv = takeFlag("--include-env", from: &args)
        let quiet = takeFlag("--quiet", from: &args)

        if staged { scanStaged(cwd: cwd, quiet: quiet) }

        let paths = args.isEmpty ? [cwd] : args.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path }
        let options = ScanOptions(paths: paths, gitHistory: history, shellHistory: shell, aiLogs: ai, skipEnvFiles: !includeEnv)
        let response = send(BrokerRequest(op: .scan, cwd: cwd, scan: options))
        report(response.findings ?? [], quiet: quiet)
    }

    /// Pre-commit: scans the staged diff. Never launches the app or prompts for Touch ID; if Redact is
    /// not running or is locked, only well-known key formats are checked.
    static func scanStaged(cwd: String, quiet: Bool) -> Never {
        let diff = shell("/usr/bin/git", ["-C", cwd, "diff", "--cached", "-U0", "--no-color", "--no-ext-diff"])
        guard diff.status == 0 else { fail("not a git repository (or git failed)") }
        if diff.output.isEmpty { exit(0) }

        var findings: [SecretScanner.Finding]?
        var note: String?
        let request = BrokerRequest(op: .scan, cwd: cwd, scan: ScanOptions(text: diff.output, textSource: "staged"))
        if let response = try? BrokerClient.send(request), response.ok {
            if response.locked == true {
                note = "Redact is locked, so only well-known key formats were checked (not your vault's values)."
            } else {
                findings = response.findings
            }
        } else {
            note = "Redact isn't running, so only well-known key formats were checked (not your vault's values)."
        }
        let result = findings ?? HealthScan.scanDiff(diff.output, scanner: SecretScanner(secrets: [:]), fallbackSource: "staged")
        if let note, !quiet || !result.isEmpty { FileHandle.standardError.write(Data("redact: \(note)\n".utf8)) }
        if result.isEmpty { exit(0) }
        report(result, quiet: false, header: "redact: this commit contains secrets:")
    }

    static func report(_ findings: [SecretScanner.Finding], quiet: Bool, header: String? = nil) -> Never {
        if findings.isEmpty {
            if !quiet { print("No secrets found.") }
            exit(0)
        }
        let out = FileHandle.standardError
        if let header { out.write(Data("\(header)\n".utf8)) }
        let grouped = Dictionary(grouping: findings, by: \.source)
        for source in grouped.keys.sorted() {
            out.write(Data("\n  \((source as NSString).abbreviatingWithTildeInPath)\n".utf8))
            for finding in grouped[source]!.sorted(by: { $0.line < $1.line }) {
                let marker = finding.kind == .vaultValue ? "vault value" : "looks like"
                out.write(Data("    line \(finding.line): \(marker) \(finding.name)\n      \(finding.preview)\n".utf8))
            }
        }
        out.write(Data("\n\(findings.count) finding\(findings.count == 1 ? "" : "s"). Move the value into Redact and rotate any key that was committed or shared.\n".utf8))
        if header != nil {
            out.write(Data("To commit anyway (e.g. a false positive): git commit --no-verify\n".utf8))
        }
        exit(1)
    }
}

// MARK: - redact hook

enum HookCommand {
    static let marker = "# redact pre-commit hook"

    static func run(_ arguments: [String], cwd: String) -> Never {
        guard let sub = arguments.first else { fail("usage: redact hook install | uninstall | zsh | bash") }
        switch sub {
        case "install": installPreCommit(cwd: cwd)
        case "uninstall": uninstallPreCommit(cwd: cwd)
        case "zsh", "bash":
            var args = Array(arguments.dropFirst())
            var tools = takeOption("--wrap", from: &args).map { $0.split(separator: ",").map(String.init) } ?? []
            if takeFlag("--wrap-wrangler", from: &args) { tools.append("wrangler") }
            let allowed = Set(Identity.Provider.allCases.map(\.tool)).subtracting(["aws"])
            let unknown = tools.filter { !allowed.contains($0) }
            if !unknown.isEmpty { fail("can't wrap \(unknown.joined(separator: ", ")); choose from \(allowed.sorted().joined(separator: ", ")) (aws uses AWS_PROFILE instead)") }
            printShellHook(sub, wrap: Array(Set(tools)).sorted())
        default: fail("unknown hook command \(sub). Try: redact hook install | uninstall | zsh | bash")
        }
    }

    static func hooksDirectory(cwd: String) -> String {
        let result = shell("/usr/bin/git", ["-C", cwd, "rev-parse", "--git-path", "hooks"])
        guard result.status == 0 else { fail("not inside a git repository") }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
    }

    /// Absolute path to this CLI, so the hook also works in GUI git clients with a minimal PATH.
    static var selfPath: String {
        let invoked = CommandLine.arguments[0]
        if invoked.contains("/") { return URL(fileURLWithPath: invoked).standardizedFileURL.path }
        return shell("/usr/bin/which", [invoked]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func installPreCommit(cwd: String) -> Never {
        let dir = hooksDirectory(cwd: cwd)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hook = (dir as NSString).appendingPathComponent("pre-commit")
        let chained = (dir as NSString).appendingPathComponent("pre-commit.local")
        if let existing = try? String(contentsOfFile: hook, encoding: .utf8) {
            if existing.contains(marker) {
                print("The Redact pre-commit hook is already installed.")
                exit(0)
            }
            // Keep the user's hook and run it after ours.
            guard !FileManager.default.fileExists(atPath: chained) else { fail("\(chained) already exists; remove or merge it first") }
            do { try FileManager.default.moveItem(atPath: hook, toPath: chained) } catch { fail("couldn't move existing hook: \(error.localizedDescription)") }
            print("Kept your existing hook as pre-commit.local; it still runs after Redact's check.")
        }
        let script = """
        #!/bin/sh
        \(marker) — blocks commits that contain secrets. Remove with: redact hook uninstall
        REDACT="$(command -v redact 2>/dev/null || echo \(shellQuote(selfPath)))"
        if [ -x "$REDACT" ]; then
          "$REDACT" scan --staged --quiet || exit 1
        fi
        HOOK_DIR="$(dirname "$0")"
        if [ -x "$HOOK_DIR/pre-commit.local" ]; then
          exec "$HOOK_DIR/pre-commit.local" "$@"
        fi
        exit 0

        """
        do {
            try script.write(toFile: hook, atomically: true, encoding: .utf8)
            chmod(hook, 0o755)
        } catch {
            fail("couldn't write \(hook): \(error.localizedDescription)")
        }
        print("Installed the Redact pre-commit hook in \((dir as NSString).abbreviatingWithTildeInPath).")
        exit(0)
    }

    static func uninstallPreCommit(cwd: String) -> Never {
        let dir = hooksDirectory(cwd: cwd)
        let hook = (dir as NSString).appendingPathComponent("pre-commit")
        let chained = (dir as NSString).appendingPathComponent("pre-commit.local")
        guard let existing = try? String(contentsOfFile: hook, encoding: .utf8), existing.contains(marker) else {
            print("No Redact pre-commit hook here.")
            exit(0)
        }
        try? FileManager.default.removeItem(atPath: hook)
        if FileManager.default.fileExists(atPath: chained) {
            try? FileManager.default.moveItem(atPath: chained, toPath: hook)
            print("Removed the Redact hook and restored your original pre-commit hook.")
        } else {
            print("Removed the Redact pre-commit hook.")
        }
        exit(0)
    }

    /// Single-quotes a string for sh.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func printShellHook(_ shellName: String, wrap tools: [String]) -> Never {
        var wrappers = ""
        if !tools.isEmpty {
            wrappers = "\n# Run these tools with the account bound to the current folder (credentials only, no project variables).\n"
            for tool in tools where tool.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil {
                wrappers += "\(tool)() { command redact run --if-any --identity-only -- \(tool) \"$@\"; }\n"
            }
        }
        if shellName == "zsh" {
            print("""
            # Redact shell integration. Add to ~/.zshrc:  eval "$(redact hook zsh)"
            # rr CMD runs CMD with this folder's secrets. rr -p NAME CMD picks a project by name (monorepo roots),
            # rr --env production CMD picks the environment.
            unalias rr 2>/dev/null
            rr() {
              local opts=()
              while [ "$1" = "-p" ] || [ "$1" = "--project" ] || [ "$1" = "--env" ]; do opts+=("$1" "$2"); shift 2; done
              command redact run "${opts[@]}" -- "$@"
            }
            _redact_chpwd() {
              local out info aws
              out="$(command redact _prompt --shell 2>/dev/null)"
              info="${out%%$'\\n'*}"
              aws=""; [[ "$out" == *$'\\n'* ]] && aws="${out#*$'\\n'}"
              if [[ "$info" != "$_REDACT_LAST" ]]; then
                _REDACT_LAST="$info"
                [[ -n "$info" ]] && print -r -- $'\\e[90m'"redact: $info"$'\\e[0m'
              fi
              export REDACT_PROMPT="$info"
              # AWS_PROFILE follows the folder, unless you set your own.
              if [[ -n "$aws" ]]; then
                if [[ -z "$AWS_PROFILE" || "$AWS_PROFILE" == "$_REDACT_AWS" ]]; then export AWS_PROFILE="$aws"; _REDACT_AWS="$aws"; fi
              elif [[ -n "$_REDACT_AWS" && "$AWS_PROFILE" == "$_REDACT_AWS" ]]; then
                unset AWS_PROFILE; _REDACT_AWS=""
              fi
            }
            autoload -Uz add-zsh-hook
            add-zsh-hook chpwd _redact_chpwd
            _redact_chpwd
            """ + wrappers)
        } else {
            print("""
            # Redact shell integration. Add to ~/.bashrc:  eval "$(redact hook bash)"
            # rr CMD runs CMD with this folder's secrets. rr -p NAME CMD picks a project by name (monorepo roots),
            # rr --env production CMD picks the environment.
            unalias rr 2>/dev/null
            rr() {
              local opts=()
              while [ "$1" = "-p" ] || [ "$1" = "--project" ] || [ "$1" = "--env" ]; do opts+=("$1" "$2"); shift 2; done
              command redact run "${opts[@]}" -- "$@"
            }
            _redact_prompt_command() {
              [ "$PWD" = "$_REDACT_PWD" ] && return
              _REDACT_PWD="$PWD"
              local out info aws
              out="$(command redact _prompt --shell 2>/dev/null)"
              info="${out%%$'\\n'*}"
              aws=""; case "$out" in *$'\\n'*) aws="${out#*$'\\n'}" ;; esac
              if [ "$info" != "$_REDACT_LAST" ]; then
                _REDACT_LAST="$info"
                [ -n "$info" ] && printf '\\033[90mredact: %s\\033[0m\\n' "$info"
              fi
              export REDACT_PROMPT="$info"
              if [ -n "$aws" ]; then
                if [ -z "$AWS_PROFILE" ] || [ "$AWS_PROFILE" = "$_REDACT_AWS" ]; then export AWS_PROFILE="$aws"; _REDACT_AWS="$aws"; fi
              elif [ -n "$_REDACT_AWS" ] && [ "$AWS_PROFILE" = "$_REDACT_AWS" ]; then
                unset AWS_PROFILE; _REDACT_AWS=""
              fi
            }
            PROMPT_COMMAND="_redact_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
            """ + wrappers)
        }
        exit(0)
    }
}

/// `redact _prompt`: one short line for shell prompts. Never launches the app, never prompts; prints
/// nothing when there is nothing to say (or Redact isn't running).
enum PromptCommand {
    static func run(cwd: String, shellFormat: Bool) -> Never {
        guard let response = try? BrokerClient.send(BrokerRequest(op: .status, cwd: cwd)), response.ok else { exit(0) }
        var parts: [String] = []
        if let project = response.project {
            parts.append("\(project) · \(response.environment ?? "")\(response.locked == true ? " (locked)" : "")")
        }
        if let identity = response.activeIdentity, identity != "wrangler:default" {
            parts.append("cf: \(identity.replacingOccurrences(of: "wrangler:", with: ""))")
        }
        if parts.isEmpty && response.locked == true && response.vaultExists == true {
            // Only mention the lock where it matters: inside a folder with a wrangler config or env files.
            if WranglerConfig.pinnedAccount(from: cwd) != nil { parts.append("locked") }
        }
        for identity in response.activeIdentities ?? [] where !identity.hasPrefix("aws:") {
            parts.append(identity.replacingOccurrences(of: "github:", with: "gh:"))
        }
        if let aws = response.awsProfile { parts.append("aws: \(aws)") }
        let line = parts.joined(separator: " · ")
        if shellFormat {
            // Line 1: display text. Line 2: AWS profile for the shell hook to export (may be empty).
            print(line)
            if let aws = response.awsProfile { print(aws) }
        } else if !line.isEmpty {
            print(line)
        }
        exit(0)
    }
}

// MARK: - Helpers

func shell(_ executable: String, _ arguments: [String], input: Data? = nil, environment: [String: String]? = nil,
           directory: String? = nil) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    let inPipe = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    do { try process.run() } catch { return (-1, "could not run \(executable): \(error.localizedDescription)") }
    if let input {
        DispatchQueue.global().async {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
