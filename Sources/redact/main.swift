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
  redact run [--env E] [--mask|--no-mask] -- CMD [ARGS...]
                                        run CMD with the project's variables injected
  redact id ls                          list Cloudflare identities and their folders
  redact id which                       which identity applies in this folder
  redact id bind NAME [dir]             bind an identity to a folder (default: this folder)
  redact activity                       recent requests: who ran what, with which variable names
  redact lock | unlock
  redact mcp                            MCP server for AI agents (names only, never values)

Output of `redact run` is masked ([redact:NAME]) whenever it is not going to your own terminal,
or when an AI agent is detected in the process tree.
"""

// MARK: - Helpers

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("redact: \(message)\n".utf8))
    exit(code)
}

func send(_ request: BrokerRequest) -> BrokerResponse {
    do {
        let response = try BrokerClient.send(request)
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
    let agent = PeerIdentity.agentInCurrentProcessTree
    if noMask && agent != nil { fail("--no-mask is not allowed when an AI agent (\(agent!)) is running this command") }

    let response = send(BrokerRequest(op: .resolve, cwd: cwd, environment: environment, command: commandLine))
    let values = response.values ?? [:]
    let interactiveHuman = agent == nil && isatty(STDOUT_FILENO) != 0 && isatty(STDERR_FILENO) != 0
    let mask = forceMask || !(noMask || interactiveHuman)
    exit(CommandRunner.run(commandLine, extraEnvironment: values, mask: mask))

case "id":
    let sub = args.first ?? "ls"
    switch sub {
    case "ls":
        let response = send(BrokerRequest(op: .identities, cwd: cwd))
        for identity in response.identities ?? [] {
            let storage = identity.mode == "wrangler-profile" ? (identity.encrypted == true ? "keychain" : "plaintext file") : "Redact vault"
            print("\(identity.name)  [\(identity.mode), \(storage)]")
            for path in identity.boundPaths { print("    \((path as NSString).abbreviatingWithTildeInPath)") }
        }
        print("\nactive here: \(response.activeIdentity ?? "-") — \(response.activeIdentitySource ?? "")")
    case "which":
        let response = send(BrokerRequest(op: .status, cwd: cwd))
        print("\(response.activeIdentity ?? "-") — \(response.activeIdentitySource ?? "")")
    case "bind":
        guard args.count >= 2 else { fail("usage: redact id bind NAME [dir]") }
        let dir = args.count > 2 ? URL(fileURLWithPath: args[2], relativeTo: URL(fileURLWithPath: cwd)).path : cwd
        let response = send(BrokerRequest(op: .bindIdentity, cwd: cwd, name: args[1], path: dir))
        print(response.message ?? "OK")
    default:
        fail("unknown id command \(sub). Try: redact id ls | which | bind NAME [dir]")
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

default:
    fail("unknown command \(command). Run `redact --help`.")
}
