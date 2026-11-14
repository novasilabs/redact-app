import Darwin
import Foundation
import RedactCore

// redact — command-line client for Redact.app. Secret values never appear in arguments or in `ls` output.

let usage = """
redact — secrets for your projects, without .env files

USAGE
  redact status                         vault state, project and Cloudflare identity for this folder
  redact init [name]                    make this folder a Redact project
  redact import [dir] [--env E]         import the folder's .env / .dev.vars files
  redact ls [--env E]                   list variable names (never values)
  redact set NAME [--env E]             set a value (read from stdin, or prompted without echo)
  redact rm NAME [--env E]              remove a variable
  redact run [-p PROJECT] [--env E] [--mask|--no-mask] [--llm-proxy] -- CMD [ARGS...]
                                        run CMD with the project's variables injected
                                        (--llm-proxy: OpenAI/Anthropic keys stay in Redact; always on for agents)
  redact id ls                          list identities (accounts) and their folders
  redact id which                       which accounts apply in this folder
  redact id add PROVIDER NAME           add a GitHub / Vercel / Supabase / Cloudflare token or AWS profile
  redact id bind NAME [dir]             bind an identity to a folder (default: this folder)
  redact push --to HOST [--env E] [--target T] [--dry-run]
                                        send secrets to cloudflare | github | vercel | supabase | aws
  redact scan [PATH...] [--history] [--shell] [--ai] [--all]
                                        find leaked secrets (vault values and known key formats)
  redact hook install | uninstall       git pre-commit hook that blocks commits containing secrets
  redact hook zsh | bash [--wrap wrangler,gh,vercel,supabase]
                                        shell integration: eval "$(redact hook zsh)" in ~/.zshrc
  redact activity                       recent requests: who ran what, with which variable names
  redact lock | unlock
  redact mcp                            MCP server for AI agents (names only, never values)

-p PROJECT works with any command: use that project instead of the folder's (e.g. one app of a monorepo,
from the repo root: `rr -p driver pnpm --filter driver dev`).

Output of `redact run` is masked ([redact:NAME]) whenever it is not going to your own terminal,
or when an AI agent is detected in the process tree.
"""

// MARK: - Helpers

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("redact: \(message)\n".utf8))
    exit(code)
}

/// The Redact.app this CLI belongs to (…/Redact.app/Contents/Resources/bin/redact), or one in /Applications.
func appBundlePath() -> String? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app" { return bundle.path }
    for candidate in ["/Applications/Redact.app", NSHomeDirectory() + "/Applications/Redact.app"]
    where FileManager.default.fileExists(atPath: candidate) { return candidate }
    return nil
}

/// Starts Redact.app in the background and waits for its socket.
func launchApp() -> Bool {
    guard let app = appBundlePath() else { return false }
    FileHandle.standardError.write(Data("redact: starting Redact…\n".utf8))
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var arguments = ["-g", "-a", app]
    if let home = ProcessInfo.processInfo.environment["REDACT_HOME"] { arguments += ["--env", "REDACT_HOME=\(home)"] }
    open.arguments = arguments
    guard (try? open.run()) != nil else { return false }
    open.waitUntilExit()
    for _ in 0..<50 {
        if FileManager.default.fileExists(atPath: RedactPaths.socket.path),
           (try? BrokerClient.send(BrokerRequest(op: .status))) != nil { return true }
        usleep(200_000)
    }
    return false
}

func send(_ request: BrokerRequest) -> BrokerResponse {
    var request = request
    if request.project == nil { request.project = selectedProject }
    do {
        let response: BrokerResponse
        do {
            response = try BrokerClient.send(request)
        } catch BrokerError.appNotRunning {
            guard launchApp() else { throw BrokerError.appNotRunning }
            response = try BrokerClient.send(request)
        }
        if !response.ok { fail(response.error ?? "request failed") }
        for warning in response.warnings ?? [] {
            FileHandle.standardError.write(Data("redact: warning: \(warning)\n".utf8))
        }
        return response
    } catch {
        fail(error.localizedDescription)
    }
}

/// Pulls `--flag value` out of the argument list.
func takeOption(_ name: String, from args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

func takeFlag(_ name: String, from args: inout [String]) -> Bool {
    guard let index = args.firstIndex(of: name) else { return false }
    args.remove(at: index)
    return true
}

func readSecretValue(name: String) -> String {
    if isatty(STDIN_FILENO) != 0 {
        var buffer = [CChar](repeating: 0, count: 8192)
        guard readpassphrase("Value for \(name) (hidden): ", &buffer, buffer.count, 0) != nil else { fail("no value read") }
        return String(cString: buffer)
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    var value = String(decoding: data, as: UTF8.self)
    if value.hasSuffix("\n") { value.removeLast() }
    return value
}

// MARK: - Commands

var args = Array(CommandLine.arguments.dropFirst())
let cwd = FileManager.default.currentDirectoryPath
/// `-p NAME` / `--project NAME` (before the command or among its options, never after `--`): use that
/// project instead of the one containing this folder. For monorepo roots.
let selectedProject: String? = {
    let end = args.firstIndex(of: "--") ?? args.endIndex
    var head = Array(args[..<end])
    let tail = Array(args[end...])
    let value = takeOption("--project", from: &head) ?? takeOption("-p", from: &head)
    args = head + tail
    return value
}()
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "-h", "--help", "help":
    print(usage)

case "status":
    let response = send(BrokerRequest(op: .status, cwd: cwd))
    print("vault:     \(response.vaultExists == false ? "not created" : (response.locked == true ? "locked" : "unlocked"))")
    if let project = response.project {
        print("project:   \(project) (\(response.projectPath ?? ""))")
        print("env:       \(response.environment ?? "") [\((response.environments ?? []).joined(separator: ", "))]")
    } else if response.locked == false {
        print("project:   none for this folder (run `redact init`)")
    }
    print("cloudflare: \(response.activeIdentity ?? "-") — \(response.activeIdentitySource ?? "")")
    if let pinned = response.pinnedAccount {
        print("account:   \(pinned) (pinned by \(((response.pinnedAccountFile ?? "") as NSString).lastPathComponent))")
    }
    for identity in response.activeIdentities ?? [] { print("identity:  \(identity)") }

case "lock":
    _ = send(BrokerRequest(op: .lock, cwd: cwd))
    print("Locked.")

case "unlock":
    _ = send(BrokerRequest(op: .unlock, cwd: cwd))
    print("Unlocked.")

case "init":
    let response = send(BrokerRequest(op: .initProject, cwd: cwd, name: args.first))
    print(response.message ?? "OK")

case "import":
    let environment = takeOption("--env", from: &args)
    let path = args.first.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: cwd)).path } ?? cwd
    let response = send(BrokerRequest(op: .importFolder, cwd: cwd, environment: environment, path: path))
    print(response.message ?? "OK")

case "ls":
    let environment = takeOption("--env", from: &args)
    let response = send(BrokerRequest(op: .list, cwd: cwd, environment: environment))
    print("\(response.project ?? "") (\(response.projectPath ?? ""))")
    let grouped = Dictionary(grouping: response.variables ?? [], by: \.environment)
    for env in response.environments ?? [] where environment == nil || env == environment {
        let vars = grouped[env] ?? []
        print("\n  \(env) (\(vars.count))")
        for v in vars {
            print("    \(v.name)\(v.linkedTo.map { "  → linked to \($0)" } ?? "")")
        }
    }

case "set":
    let environment = takeOption("--env", from: &args)
    guard let name = args.first else { fail("usage: redact set NAME [--env E]  (value from stdin)") }
    if args.count > 1 { fail("don't pass the value as an argument (it would end up in your shell history). Pipe it in or type it at the prompt.") }
    let value = readSecretValue(name: name)
    let response = send(BrokerRequest(op: .set, cwd: cwd, environment: environment, name: name, value: value))
    print(response.message ?? "OK")

case "rm":
    let environment = takeOption("--env", from: &args)
    guard let name = args.first else { fail("usage: redact rm NAME [--env E]") }
    let response = send(BrokerRequest(op: .remove, cwd: cwd, environment: environment, name: name))
    print(response.message ?? "OK")

case "run":
    guard let dash = args.firstIndex(of: "--"), dash + 1 < args.count else { fail("usage: redact run [--env E] -- CMD [ARGS...]") }
    var options = Array(args[..<dash])
    let commandLine = Array(args[(dash + 1)...])
    let environment = takeOption("--env", from: &options)
    let forceMask = takeFlag("--mask", from: &options)
    let noMask = takeFlag("--no-mask", from: &options)
    let ifAny = takeFlag("--if-any", from: &options)
    let identityOnly = takeFlag("--identity-only", from: &options)
    let llmProxy = takeFlag("--llm-proxy", from: &options)
    let agent = PeerIdentity.agentInCurrentProcessTree
    if noMask && agent != nil { fail("--no-mask is not allowed when an AI agent (\(agent!)) is running this command") }

    var resolveRequest = BrokerRequest(op: .resolve, cwd: cwd, environment: environment, command: commandLine)
    resolveRequest.project = selectedProject
    resolveRequest.ifAny = ifAny ? true : nil
    resolveRequest.identityOnly = identityOnly ? true : nil
    resolveRequest.llmProxy = llmProxy ? true : nil
    let response: BrokerResponse
    if ifAny {
        // Wrappers: never start the app just to find there's nothing to inject.
        guard let direct = try? BrokerClient.send(resolveRequest) else {
            exit(CommandRunner.run(commandLine, extraEnvironment: [:], mask: false))
        }
        if !direct.ok { fail(direct.error ?? "request failed") }
        response = direct
    } else {
        response = send(resolveRequest)
    }
    var values = response.values ?? [:]
    // Workers: let wrangler dev / the Cloudflare Vite plugin see these values instead of .dev.vars.
    let wrangler = WranglerDevSecrets.plan(cwd: cwd, projectRoot: response.projectPath, injected: values)
    values.merge(wrangler.environment) { current, _ in current }
    if let warning = wrangler.warning { FileHandle.standardError.write(Data("redact: note: \(warning)\n".utf8)) }
    let interactiveHuman = agent == nil && isatty(STDOUT_FILENO) != 0 && isatty(STDERR_FILENO) != 0
    let mask = forceMask || !(noMask || interactiveHuman)
    let status = CommandRunner.run(commandLine, extraEnvironment: values, mask: mask,
                                   notSecret: LLMProxy.baseURLVariables(forProxied: response.proxiedNames ?? []))
    if let sessions = response.proxySessions, !sessions.isEmpty {
        var end = BrokerRequest(op: .endProxy, cwd: cwd)
        end.proxySessions = sessions
        _ = try? BrokerClient.send(end)
    }
    exit(status)

case "id":
    let sub = args.first ?? "ls"
    switch sub {
    case "ls":
        let response = send(BrokerRequest(op: .identities, cwd: cwd))
        for identity in response.identities ?? [] {
            let storage: String
            switch identity.mode {
            case "wrangler-profile": storage = identity.encrypted == true ? "keychain" : "plaintext file"
            case "aws-profile": storage = "AWS profile \(identity.scope ?? "")"
            default: storage = "token in Redact vault"
            }
            print("\(identity.name)  [\(identity.provider), \(storage)]")
            for path in identity.boundPaths { print("    \((path as NSString).abbreviatingWithTildeInPath)") }
        }
        print("\nactive here: cloudflare: \(response.activeIdentity ?? "-") — \(response.activeIdentitySource ?? "")")
        for identity in response.activeIdentities ?? [] { print("             \(identity)") }
    case "add":
        var rest = Array(args.dropFirst())
        let scope = takeOption("--scope", from: &rest) ?? takeOption("--account", from: &rest)
        let profile = takeOption("--profile", from: &rest)
        let fromGH = takeOption("--from-gh", from: &rest)
        guard rest.count == 2 else {
            fail("""
            usage: redact id add PROVIDER NAME [--scope S]     token read from stdin or prompted
                   redact id add github NAME --from-gh USER     use a token from `gh auth token --user USER`
                   redact id add aws NAME --profile PROFILE     use a profile from ~/.aws/config
              PROVIDER: cloudflare | github | vercel | supabase | aws   (--scope: Cloudflare account ID)
            """)
        }
        let provider = rest[0].lowercased()
        var token: String?
        if provider == "aws" {
            guard profile != nil else { fail("AWS identities need --profile NAME") }
        } else if let fromGH {
            let result = shell("/usr/bin/env", ["gh", "auth", "token", "--user", fromGH])
            guard result.status == 0 else { fail("gh auth token failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
            token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = readSecretValue(name: "\(provider) token")
        }
        var request = BrokerRequest(op: .addIdentity, cwd: cwd, name: rest[1], value: token)
        request.provider = provider
        request.scope = provider == "aws" ? profile : scope
        print(send(request).message ?? "OK")
    case "which":
        let response = send(BrokerRequest(op: .status, cwd: cwd))
        print("cloudflare: \(response.activeIdentity ?? "-") — \(response.activeIdentitySource ?? "")")
        for identity in response.activeIdentities ?? [] { print(identity) }
        if let pinned = response.pinnedAccount {
            print("account \(pinned) pinned by \(response.pinnedAccountFile ?? "")")
        } else {
            print("no account_id in wrangler config (tip: pin one so a deploy can't reach the wrong account)")
        }
    case "bind":
        guard args.count >= 2 else { fail("usage: redact id bind NAME [dir]") }
        let dir = args.count > 2 ? URL(fileURLWithPath: args[2], relativeTo: URL(fileURLWithPath: cwd)).path : cwd
        let response = send(BrokerRequest(op: .bindIdentity, cwd: cwd, name: args[1], path: dir))
        print(response.message ?? "OK")
    default:
        fail("unknown id command \(sub). Try: redact id ls | which | add | bind NAME [dir]")
    }

case "activity":
    let response = send(BrokerRequest(op: .activity, cwd: cwd))
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d HH:mm:ss"
    for entry in response.activity ?? [] {
        let who = entry.agent ?? entry.caller
        print("\(formatter.string(from: entry.date))  \(entry.outcome.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))  \(who.padding(toLength: 14, withPad: " ", startingAt: 0))  \(entry.command)")
        if !entry.variableNames.isEmpty { print("                 vars: \(entry.variableNames.joined(separator: ", "))") }
    }

case "mcp":
    MCPServer.run()

case "scan":
    ScanCommand.run(args, cwd: cwd)

case "hook":
    HookCommand.run(args, cwd: cwd)

case "push":
    PushCommand.run(args, cwd: cwd)

case "_prompt":
    PromptCommand.run(cwd: cwd, shellFormat: args.contains("--shell"))

default:
    fail("unknown command \(command). Run `redact --help`.")
}
