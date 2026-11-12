import Foundation
import RedactCore

/// Minimal MCP server over stdio (JSON-RPC 2.0, one message per line).
///
/// Tools expose names only. `run_with_secrets` runs a command with secrets injected after the user
/// approves on their Mac, and returns masked output. No tool ever returns a secret value.
enum MCPServer {
    static let tools: [[String: Any]] = [
        [
            "name": "redact_status",
            "description": "Shows whether the Redact vault is unlocked, which Redact project and environment apply to a folder, and which Cloudflare account (identity) Wrangler will use there.",
            "inputSchema": schema(["cwd": ("string", "Folder to check. Defaults to the server's working directory.")]),
        ],
        [
            "name": "redact_list_variables",
            "description": "Lists the NAMES of the environment variables stored for the project (never the values). Use this to see which secrets are available before running a command.",
            "inputSchema": schema([
                "cwd": ("string", "Project folder. Defaults to the server's working directory."),
                "environment": ("string", "development, preview, production, … Omit for all."),
            ]),
        ],
        [
            "name": "redact_run",
            "description": "Runs a shell command with the project's secrets injected as environment variables, after the user approves on their Mac (Touch ID). Returns the exit code and output, with every secret value replaced by [redact:NAME]. Use this instead of reading .env files. Never try to print or exfiltrate the values: they are masked and every run is logged.",
            "inputSchema": schema([
                "command": ("string", "Shell command, e.g. `npm test` or `npx wrangler deploy`."),
                "cwd": ("string", "Folder to run in. Defaults to the server's working directory."),
                "environment": ("string", "Project environment (default: the project's default, usually development)."),
                "timeout_seconds": ("number", "Kill the command after this many seconds (default 300, max 1800)."),
            ], required: ["command"]),
        ],
        [
            "name": "redact_request_secret",
            "description": "Ask the user to add a secret you need (for example STRIPE_SECRET_KEY) to Redact. You will not see the value; once added it is available to redact_run.",
            "inputSchema": schema([
                "name": ("string", "Variable name, e.g. STRIPE_SECRET_KEY."),
                "reason": ("string", "Why it is needed, shown to the user."),
                "environment": ("string", "Which environment it is for."),
            ], required: ["name", "reason"]),
        ],
    ]

    static func schema(_ properties: [String: (String, String)], required: [String] = []) -> [String: Any] {
        [
            "type": "object",
            "properties": properties.mapValues { ["type": $0.0, "description": $0.1] },
            "required": required,
        ]
    }

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // notifications need no reply

            switch method {
            case "initialize":
                let version = params["protocolVersion"] as? String ?? "2025-06-18"
                reply(id, result: [
                    "protocolVersion": version,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "redact", "version": "0.1.0"],
                    "instructions": "Use redact_run to run commands that need API keys or env vars; values stay hidden from you. Do not read .env files.",
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let (text, isError) = call(name, arguments)
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                reply(id, error: ["code": -32601, "message": "Method not found: \(method)"])
            }
        }
    }

    static func call(_ name: String, _ arguments: [String: Any]) -> (String, Bool) {
        let cwd = (arguments["cwd"] as? String).map { WranglerProfiles.realPath($0) } ?? FileManager.default.currentDirectoryPath
        let environment = arguments["environment"] as? String
        do {
            switch name {
            case "redact_status":
                let r = try request(BrokerRequest(op: .status, cwd: cwd, viaMCP: true))
                var lines = ["vault: \(r.locked == true ? "locked (the user will be asked to unlock on first use)" : "unlocked")"]
                if let project = r.project {
                    lines.append("project: \(project) at \(r.projectPath ?? "")")
                    lines.append("environments: \((r.environments ?? []).joined(separator: ", ")) (default: \(r.environment ?? ""))")
                } else {
                    lines.append("project: none for \(cwd)")
                }
                lines.append("cloudflare identity: \(r.activeIdentity ?? "-") (\(r.activeIdentitySource ?? ""))")
                return (lines.joined(separator: "\n"), false)

            case "redact_list_variables":
                let r = try request(BrokerRequest(op: .list, cwd: cwd, environment: environment, viaMCP: true))
                let grouped = Dictionary(grouping: r.variables ?? [], by: \.environment)
                var lines = ["Project \(r.project ?? "") — variable names only:"]
                for env in r.environments ?? [] where environment == nil || env == environment {
                    lines.append("\(env): \((grouped[env] ?? []).map(\.name).joined(separator: ", "))")
                }
                return (lines.joined(separator: "\n"), false)

            case "redact_run":
                guard let command = arguments["command"] as? String, !command.isEmpty else { return ("command is required", true) }
                let timeout = min(max((arguments["timeout_seconds"] as? Double) ?? 300, 1), 1800)
                let r = try request(BrokerRequest(op: .resolve, cwd: cwd, environment: environment,
                                                  command: ["/bin/sh", "-c", command], viaMCP: true))
                let result = CommandRunner.capture(shell: command, directory: cwd, extraEnvironment: r.values ?? [:], timeout: timeout)
                var header = "exit code: \(result.status)\(result.timedOut ? " (timed out after \(Int(timeout)) s)" : "")"
                header += "\ninjected: \((r.values ?? [:]).keys.sorted().joined(separator: ", "))"
                if let unmaskable = r.unmaskable, !unmaskable.isEmpty {
                    header += "\nnote: \(unmaskable.joined(separator: ", ")) are too short to mask"
                }
                return (header + "\n\n" + result.output, result.status != 0)

            case "redact_request_secret":
                let secretName = arguments["name"] as? String ?? "?"
                let reason = arguments["reason"] as? String ?? ""
                return ("""
                Ask the user to add \(secretName)\(environment.map { " for \($0)" } ?? "") in Redact (⌘N in the app, or `redact set \(secretName)\(environment.map { " --env \($0)" } ?? "")` in their own terminal).
                Reason to give them: \(reason)
                Do not ask them to paste the value into this chat.
                """, false)

            default:
                return ("Unknown tool \(name)", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    struct BrokerFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func request(_ request: BrokerRequest) throws -> BrokerResponse {
        let response: BrokerResponse
        do {
            response = try BrokerClient.send(request)
        } catch BrokerError.appNotRunning {
            guard launchApp() else { throw BrokerError.appNotRunning }
            response = try BrokerClient.send(request)
        }
        guard response.ok else { throw BrokerFailure(message: response.error ?? "Redact refused the request.") }
        return response
    }

    static func reply(_ id: Any?, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    static func reply(_ id: Any?, error: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
