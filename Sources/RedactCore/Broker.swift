import Darwin
import Foundation

/// Locations of Redact's files. `REDACT_HOME` overrides the folder (used by tests).
public enum RedactPaths {
    public static var home: URL {
        #if REDACT_DEV
        if let override = ProcessInfo.processInfo.environment["REDACT_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Redact", isDirectory: true)
    }

    public static var vault: URL { home.appendingPathComponent("vault.redact") }
    public static var socket: URL { home.appendingPathComponent("agent.sock") }
}

// MARK: - Messages

public struct BrokerRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable {
        case status, unlock, lock
        case list, resolve, set, remove
        case importFolder, initProject
        case identities, bindIdentity, addIdentity
        case activity
        case scan
        case endProxy
    }

    public var op: Op
    public var cwd: String
    public var environment: String?
    public var name: String?
    public var value: String?
    public var command: [String]?
    public var path: String?
    /// Set by `redact mcp` so approvals name the agent even when the process tree is ambiguous.
    public var viaMCP: Bool?
    public var scan: ScanOptions?
    /// `resolve`: succeed with no values when the folder has no project or identity (shell wrappers).
    public var ifAny: Bool?
    /// Picks a project by name instead of by folder (`redact -p NAME …`), e.g. one app of a monorepo
    /// from the repo root. The broker treats the request as coming from that project's folder.
    public var project: String?
    /// `resolve`: only the folder's identity credentials, not the project's variables (tool wrappers).
    public var identityOnly: Bool?
    /// `addIdentity`: provider raw value and optional scope (Cloudflare account ID, AWS profile name).
    public var provider: String?
    public var scope: String?
    /// `resolve`: route OpenAI/Anthropic keys through the local proxy (always on for agents).
    public var llmProxy: Bool?
    /// `endProxy`: placeholders to invalidate when the command has exited.
    public var proxySessions: [String]?

    public init(op: Op, cwd: String = FileManager.default.currentDirectoryPath, environment: String? = nil,
                name: String? = nil, value: String? = nil, command: [String]? = nil, path: String? = nil, viaMCP: Bool? = nil,
                scan: ScanOptions? = nil, ifAny: Bool? = nil) {
        self.op = op
        self.cwd = cwd
        self.environment = environment
        self.name = name
        self.value = value
        self.command = command
        self.path = path
        self.viaMCP = viaMCP
        self.scan = scan
        self.ifAny = ifAny
    }
}

public struct VariableInfo: Codable, Sendable, Equatable {
    public var name: String
    public var environment: String
    public var linkedTo: String?
    public var updatedAt: Date

    public init(name: String, environment: String, linkedTo: String?, updatedAt: Date) {
        self.name = name
        self.environment = environment
        self.linkedTo = linkedTo
        self.updatedAt = updatedAt
    }
}

public struct IdentityInfo: Codable, Sendable, Equatable {
    public var name: String
    public var provider: String
    public var mode: String           // "wrangler-profile" | "api-token"
    public var boundPaths: [String]
    public var encrypted: Bool?       // wrangler profiles: stored in keychain?
    public var scope: String?

    public init(name: String, provider: String, mode: String, boundPaths: [String], encrypted: Bool?, scope: String? = nil) {
        self.scope = scope
        self.name = name
        self.provider = provider
        self.mode = mode
        self.boundPaths = boundPaths
        self.encrypted = encrypted
    }
}

public struct BrokerResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var locked: Bool?
    public var vaultExists: Bool?
    public var project: String?
    public var projectPath: String?
    public var environment: String?
    public var environments: [String]?
    public var variables: [VariableInfo]?
    /// Only for `resolve`: the values to inject. Never returned to MCP clients.
    public var values: [String: String]?
    /// Names whose values are too short to mask in output.
    public var unmaskable: [String]?
    public var identities: [IdentityInfo]?
    public var activeIdentity: String?
    public var activeIdentitySource: String?
    public var warnings: [String]?
    public var message: String?
    public var activity: [ActivityEntry]?
    public var findings: [SecretScanner.Finding]?
    /// `resolve`: names in `values` that are cloud credentials from an identity, not project variables.
    public var identityNames: [String]?
    /// `resolve`: provider of each identity name (e.g. GH_TOKEN → github).
    public var identityProviders: [String: String]?
    /// `status`: identities that apply in this folder, e.g. ["github: work", "aws: acme-prod"].
    public var activeIdentities: [String]?
    /// `status`: AWS profile bound to this folder (not a secret), for the shell hook.
    public var awsProfile: String?
    /// `resolve`: key variables replaced by proxy placeholders, and the placeholders to end afterwards.
    public var proxiedNames: [String]?
    public var proxySessions: [String]?
    /// `account_id` pinned by the folder's wrangler.toml / wrangler.jsonc, if any.
    public var pinnedAccount: String?
    public var pinnedAccountFile: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }

    public static func failure(_ message: String) -> BrokerResponse { BrokerResponse(ok: false, error: message) }
}

// MARK: - Transport

public enum BrokerError: LocalizedError {
    #if REDACT_DEV
    static let devHint: String? = " Set REDACT_HOME to a shorter folder."
    #else
    static let devHint: String? = nil
    #endif
    case appNotRunning
    case transport(String)
    case socketPathTooLong(path: String, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .appNotRunning: "Redact isn't running. Open Redact.app and try again."
        case .transport(let detail): "Could not talk to Redact: \(detail)"
        case let .socketPathTooLong(path, limit):
            "The agent socket path is \(path.utf8.count) bytes, longer than the \(limit) a Unix socket allows: \(path)."
                + (Self.devHint ?? "")
        }
    }
}

enum SocketIO {
    /// Longest path `sun_path` can hold (it needs a trailing NUL).
    static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// Throws instead of truncating: a cut-off path would bind or connect somewhere else entirely.
    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else { throw BrokerError.socketPathTooLong(path: path, limit: maxPathLength) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes + [0]) }
        return address
    }

    static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads one newline-terminated message (max 16 MB).
    static func readLine(_ fd: Int32) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return result.isEmpty ? nil : result }
            if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[0..<newline])
                return result
            }
            result.append(contentsOf: buffer[0..<n])
            if result.count > 16 * 1024 * 1024 { return nil }
        }
    }
}

public enum BrokerClient {
    /// Sends one request and waits for the response. Blocks (approvals can take a while).
    public static func send(_ request: BrokerRequest, socketPath: String = RedactPaths.socket.path) throws -> BrokerResponse {
        var address = try SocketIO.address(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerError.transport("socket() failed") }
        defer { close(fd) }
        guard SocketIO.withSockaddr(&address, { connect(fd, $0, $1) }) == 0 else { throw BrokerError.appNotRunning }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        guard SocketIO.writeAll(fd, payload) else { throw BrokerError.transport("write failed") }
        guard let line = SocketIO.readLine(fd) else { throw BrokerError.transport("no response") }
        let decoder = JSONDecoder()
        return try decoder.decode(BrokerResponse.self, from: line)
    }
}

/// Unix-socket server run by Redact.app. Each connection carries one request.
public final class BrokerServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BrokerRequest, PeerIdentity) async -> BrokerResponse

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1

    public init(path: String = RedactPaths.socket.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        var address = try SocketIO.address(path)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerError.transport("socket() failed") }
        // Restrictive umask so the socket is never briefly world-accessible.
        let oldMask = umask(0o077)
        let bound = SocketIO.withSockaddr(&address) { bind(fd, $0, $1) }
        umask(oldMask)
        guard bound == 0 else { close(fd); throw BrokerError.transport("bind failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw BrokerError.transport("listen failed") }
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "redact.broker.accept"
        thread.start()
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // socket closed
            }
            let handler = self.handler
            Task.detached {
                defer { close(client) }
                let response: BrokerResponse
                if let line = SocketIO.readLine(client),
                   let request = try? JSONDecoder().decode(BrokerRequest.self, from: line) {
                    do {
                        let peer = try PeerIdentity.of(socket: client)
                        guard peer.uid == getuid() else {
                            _ = SocketIO.writeAll(client, Self.encode(.failure("Wrong user.")))
                            return
                        }
                        response = await handler(request, peer)
                    } catch {
                        response = .failure("Could not identify caller: \(error)")
                    }
                } else {
                    response = .failure("Malformed request.")
                }
                _ = SocketIO.writeAll(client, Self.encode(response))
            }
        }
    }

    static func encode(_ response: BrokerResponse) -> Data {
        var data = (try? JSONEncoder().encode(response)) ?? Data("{\"ok\":false}".utf8)
        data.append(0x0A)
        return data
    }
}
