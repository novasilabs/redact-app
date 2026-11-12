import Darwin
import Foundation
import RedactCore

/// `redact push`: sends a project environment's secrets to a host through the host's own CLI.
/// Values only ever travel over stdin, never as command-line arguments.
enum PushCommand {
    enum Host: String, CaseIterable {
        case cloudflare, github, vercel, supabase, aws

        var tool: String {
            switch self {
            case .cloudflare: "wrangler"
            case .github: "gh"
            case .vercel: "vercel"
            case .supabase: "supabase"
            case .aws: "aws"
            }
        }

        var installHint: String {
            switch self {
            case .cloudflare: "npm i -g wrangler"
            case .github: "brew install gh"
            case .vercel: "npm i -g vercel"
            case .supabase: "brew install supabase/tap/supabase"
            case .aws: "brew install awscli"
            }
        }

        /// Adapters not yet run against the real tool on a real account.
        var untested: Bool { self == .vercel || self == .aws }
    }

    static let usage = """
    usage: redact push --to HOST [--env E] [--target T] [--only A,B] [--dry-run] [--yes]
      HOST     cloudflare | github | vercel | supabase | aws
      --env    Redact environment to push (default: the project's default)
      --target where it goes on the host:
                 cloudflare  Wrangler environment (wrangler --env T)
                 github      GitHub Actions environment (default: repository secrets)
                 vercel      development | preview | production (default: same as --env)
                 aws         Secrets Manager secret id (default: <project>/<env>)
      --only   push just these names
    """

    static func run(_ arguments: [String], cwd: String) -> Never {
        var args = arguments
        guard let hostName = takeOption("--to", from: &args), let host = Host(rawValue: hostName.lowercased()) else { fail(usage) }
        let environment = takeOption("--env", from: &args)
        let target = takeOption("--target", from: &args)
        let only = takeOption("--only", from: &args).map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let dryRun = takeFlag("--dry-run", from: &args)
        let yes = takeFlag("--yes", from: &args) || takeFlag("-y", from: &args)
        if !args.isEmpty { fail("unexpected arguments: \(args.joined(separator: " "))\n\(usage)") }

        guard toolPath(host.tool) != nil else { fail("\(host.tool) isn't installed. Install it with: \(host.installHint)") }

        if dryRun {
            // Names only: no values, so no approval or Touch ID needed.
            let listing = send(BrokerRequest(op: .list, cwd: cwd, environment: environment))
            let env = environment ?? listing.environment ?? "development"
            var names = (listing.variables ?? []).filter { $0.environment == env }.map(\.name)
            if let only { names = names.filter { only.contains($0) } }
            if host == .supabase { names = names.filter { !$0.hasPrefix("SUPABASE_") } }
            print(describe(host: host, names: names.sorted(), environment: env, target: target, project: listing.project ?? ""))
            print("(dry run: nothing was sent)")
            exit(0)
        }

        // Same approval path as `redact run`: agents get the panel + Touch ID.
        var description = ["redact", "push", "--to", host.rawValue]
        if let environment { description += ["--env", environment] }
        if let target { description += ["--target", target] }
        let response = send(BrokerRequest(op: .resolve, cwd: cwd, environment: environment, command: description))
        let identityNames = Set(response.identityNames ?? [])
        var secrets = (response.values ?? [:]).filter { !identityNames.contains($0.key) }
        if let only {
            let missing = only.subtracting(secrets.keys)
            if !missing.isEmpty { fail("not set in this environment: \(missing.sorted().joined(separator: ", "))") }
            secrets = secrets.filter { only.contains($0.key) }
        }
        var skipped: [String] = []
        if host == .supabase {
            // Supabase reserves the SUPABASE_ prefix for its own variables.
            skipped = secrets.keys.filter { $0.hasPrefix("SUPABASE_") }.sorted()
            for name in skipped { secrets.removeValue(forKey: name) }
        }
        guard !secrets.isEmpty else { fail("nothing to push") }

        let env = response.environment ?? environment ?? "development"
        let project = response.project ?? (cwd as NSString).lastPathComponent
        let plan = describe(host: host, names: secrets.keys.sorted(), environment: env, target: target, project: project)
        print(plan)
        if !skipped.isEmpty { print("Skipping (reserved by Supabase): \(skipped.joined(separator: ", "))") }
        if host.untested { print("Note: the \(host.rawValue) adapter hasn't been tested against a real account yet.") }

        if !yes {
            guard isatty(STDIN_FILENO) != 0 else { fail("refusing to push without confirmation; re-run with --yes") }
            print("Push now? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print("Cancelled."); exit(1) }
        }

        // Each host's CLI gets only its own provider's identity (e.g. gh gets GH_TOKEN, not the Cloudflare token).
        var toolEnvironment = ProcessInfo.processInfo.environment
        let providers = response.identityProviders ?? [:]
        for name in identityNames where providers[name] == host.rawValue {
            toolEnvironment[name] = response.values?[name]
        }
        fflush(stdout)

        let ok: Bool
        switch host {
        case .cloudflare: ok = pushCloudflare(secrets, target: target, cwd: cwd, environment: toolEnvironment)
        case .github: ok = pushGitHub(secrets, target: target, cwd: cwd, environment: toolEnvironment)
        case .vercel: ok = pushVercel(secrets, target: target ?? vercelTarget(env), cwd: cwd, environment: toolEnvironment)
        case .supabase: ok = pushSupabase(secrets, cwd: cwd, environment: toolEnvironment)
        case .aws: ok = pushAWS(secrets, secretID: target ?? "\(project)/\(env)", cwd: cwd, environment: toolEnvironment)
        }
        if ok { print("Pushed \(secrets.count) secret\(secrets.count == 1 ? "" : "s") to \(host.rawValue).") }
        exit(ok ? 0 : 1)
    }

    static func describe(host: Host, names: [String], environment: String, target: String?, project: String) -> String {
        let destination: String
        switch host {
        case .cloudflare: destination = "the Worker in this folder" + (target.map { " (wrangler env \($0))" } ?? "")
        case .github: destination = target.map { "GitHub Actions environment \($0) of this repository" } ?? "GitHub Actions secrets of this repository"
        case .vercel: destination = "Vercel \(target ?? vercelTarget(environment)) environment of the linked project"
        case .supabase: destination = "Edge Function secrets of the linked Supabase project"
        case .aws: destination = "AWS Secrets Manager secret \(target ?? "\(project)/\(environment)") (one JSON secret)"
        }
        return "Push \(names.count) secret\(names.count == 1 ? "" : "s") from \(project) · \(environment) to \(destination):\n  " + names.joined(separator: ", ")
    }

    static func vercelTarget(_ environment: String) -> String {
        ["development", "preview", "production"].contains(environment) ? environment : "preview"
    }

    static func toolPath(_ tool: String) -> String? {
        let result = shell("/usr/bin/env", ["which", tool])
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !path.isEmpty ? path : nil
    }

    /// Runs `tool args` with `input` on stdin, streaming the tool's output (masked) to the terminal.
    static func runTool(_ tool: String, _ arguments: [String], input: Data, cwd: String, environment: [String: String],
                        secrets: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe
        fflush(stdout)
        do { try process.run() } catch { FileHandle.standardError.write(Data("redact: couldn't run \(tool): \(error)\n".utf8)); return false }
        inPipe.fileHandleForWriting.write(input)
        try? inPipe.fileHandleForWriting.close()
        // Mask the tool's output too, in case it echoes a value.
        let redactor = Redactor(secrets: secrets)
        let reader = outPipe.fileHandleForReading
        while true {
            let data = reader.availableData
            if data.isEmpty { break }
            FileHandle.standardOutput.write(Data(redactor.feed(data)))
        }
        FileHandle.standardOutput.write(Data(redactor.finish()))
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Hosts

    static func pushCloudflare(_ secrets: [String: String], target: String?, cwd: String, environment: [String: String]) -> Bool {
        // `wrangler secret bulk` with no file reads JSON from stdin.
        var arguments = ["secret", "bulk"]
        if let target { arguments += ["--env", target] }
        guard let json = try? JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys]) else { return false }
        return runTool("wrangler", arguments, input: json, cwd: cwd, environment: environment, secrets: secrets)
    }

    static func pushGitHub(_ secrets: [String: String], target: String?, cwd: String, environment: [String: String]) -> Bool {
        // `gh secret set -f -` reads dotenv from stdin.
        var arguments = ["secret", "set", "-f", "-"]
        if let target { arguments += ["--env", target] }
        return runTool("gh", arguments, input: Data(EnvFile.serialize(secrets).utf8), cwd: cwd, environment: environment, secrets: secrets)
    }

    static func pushVercel(_ secrets: [String: String], target: String, cwd: String, environment: [String: String]) -> Bool {
        // One variable at a time; the value is read from stdin. --force replaces an existing value.
        var ok = true
        for name in secrets.keys.sorted() {
            print("  \(name)…")
            ok = runTool("vercel", ["env", "add", name, target, "--force"], input: Data(secrets[name]!.utf8), cwd: cwd,
                         environment: environment, secrets: secrets) && ok
        }
        return ok
    }

    static func pushSupabase(_ secrets: [String: String], cwd: String, environment: [String: String]) -> Bool {
        runTool("supabase", ["secrets", "set", "--env-file", "/dev/stdin"], input: Data(EnvFile.serialize(secrets).utf8),
                cwd: cwd, environment: environment, secrets: secrets)
    }

    static func pushAWS(_ secrets: [String: String], secretID: String, cwd: String, environment: [String: String]) -> Bool {
        guard let json = try? JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys]) else { return false }
        let exists = shell("/usr/bin/env", ["aws", "secretsmanager", "describe-secret", "--secret-id", secretID],
                           environment: environment, directory: cwd).status == 0
        let arguments = exists
            ? ["secretsmanager", "put-secret-value", "--secret-id", secretID, "--secret-string", "file:///dev/stdin"]
            : ["secretsmanager", "create-secret", "--name", secretID, "--secret-string", "file:///dev/stdin"]
        return runTool("aws", arguments, input: json, cwd: cwd, environment: environment, secrets: secrets)
    }
}
