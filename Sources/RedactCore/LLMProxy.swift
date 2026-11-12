import Foundation
import Network

/// Local proxy for OpenAI and Anthropic API keys (PRD §6.4).
///
/// A command gets a placeholder key and a base URL pointing here; the proxy swaps in the real key and
/// forwards to the provider. The command can call the API but never holds the key.
///
/// - Listens on 127.0.0.1 only, on a random port.
/// - Forwards only to the fixed provider hosts (no open proxy, no SSRF).
/// - After rewriting the request head, bytes are piped both ways untouched, so streaming (SSE) works and
///   compression is irrelevant. Upstream is asked to close after one response (`Connection: close`).
public final class LLMProxy: @unchecked Sendable {
    public enum Provider: String, CaseIterable, Sendable {
        case openai, anthropic

        public var keyVariable: String { self == .openai ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY" }
        public var baseURLVariable: String { self == .openai ? "OPENAI_BASE_URL" : "ANTHROPIC_BASE_URL" }
        var pathPrefix: String { "/\(rawValue)" }

        /// SDK convention: OpenAI's base URL includes /v1, Anthropic's does not.
        public func baseURL(port: UInt16) -> String {
            self == .openai ? "http://127.0.0.1:\(port)/openai/v1" : "http://127.0.0.1:\(port)/anthropic"
        }
    }

    public struct Upstream: Sendable {
        public var host: String
        public var port: UInt16
        public var useTLS: Bool
        public init(host: String, port: UInt16 = 443, useTLS: Bool = true) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
        }
    }

    public static let defaultUpstreams: [Provider: Upstream] = [
        .openai: Upstream(host: "api.openai.com"),
        .anthropic: Upstream(host: "api.anthropic.com"),
    ]

    public static let placeholderPrefix = "redact-proxy-"

    /// Base-URL variables the proxy sets for these key variables (not secret; don't mask them).
    public static func baseURLVariables(forProxied names: [String]) -> Set<String> {
        Set(Provider.allCases.filter { names.contains($0.keyVariable) }.map(\.baseURLVariable))
    }

    struct Session {
        let provider: Provider
        let key: String
        let expires: Date
        let label: String
    }

    private let upstreams: [Provider: Upstream]
    private let queue = DispatchQueue(label: "redact.llm-proxy")
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var counts: [String: Int] = [:]
    private var listener: NWListener?
    public private(set) var port: UInt16?

    public init(upstreams: [Provider: Upstream] = LLMProxy.defaultUpstreams) {
        self.upstreams = upstreams
    }

    // MARK: - Lifecycle

    /// Starts listening (idempotent). Returns the port.
    @discardableResult
    public func start() throws -> UInt16 {
        if let port { return port }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let failure = Box<Error?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure.value = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let error = failure.value { throw error }
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.listener = listener
        self.port = port
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        endAll()
    }

    // MARK: - Sessions

    /// Registers a real key and returns the placeholder to give the command instead.
    public func createSession(provider: Provider, key: String, label: String, ttl: TimeInterval = 12 * 3600) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Self.placeholderPrefix + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        lock.lock()
        sessions[token] = Session(provider: provider, key: key, expires: Date().addingTimeInterval(ttl), label: label)
        lock.unlock()
        return token
    }

    public func endSessions(_ placeholders: [String]) {
        lock.lock()
        for token in placeholders { sessions.removeValue(forKey: token) }
        lock.unlock()
    }

    public func endAll() {
        lock.lock()
        sessions.removeAll()
        lock.unlock()
    }

    /// Requests forwarded per session label (for the activity log).
    public func requestCount(label: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[label] ?? 0
    }

    public var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.filter { $0.expires > Date() }.count
    }

    private func session(for token: String, provider: Provider) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[token], session.provider == provider else { return nil }
        if session.expires < Date() {
            sessions.removeValue(forKey: token)
            return nil
        }
        counts[session.label, default: 0] += 1
        return session
    }

    // MARK: - Connections

    private func handle(_ client: NWConnection) {
        client.start(queue: queue)
        readHead(client, buffer: Data())
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[buffer.startIndex..<end.upperBound]
                let rest = buffer[end.upperBound...]
                self.forward(client, head: Data(head), rest: Data(rest))
            } else if buffer.count > 65536 || isComplete || error != nil {
                self.respond(client, status: "400 Bad Request", message: "Redact proxy: malformed request")
            } else {
                self.readHead(client, buffer: buffer)
            }
        }
    }

    struct ParsedHead {
        var method: String
        var path: String
        var headers: [(String, String)]
    }

    static func parse(_ head: Data) -> ParsedHead? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        let headers: [(String, String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return ParsedHead(method: requestLine[0], path: requestLine[1], headers: headers)
    }

    /// Hop-by-hop and credential headers that must not pass through as-is.
    static let droppedHeaders: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "proxy-authorization", "te", "upgrade",
        "authorization", "x-api-key",
    ]

    private func forward(_ client: NWConnection, head: Data, rest: Data) {
        guard let request = Self.parse(head) else {
            respond(client, status: "400 Bad Request", message: "Redact proxy: malformed request")
            return
        }
        guard let provider = Provider.allCases.first(where: { request.path == $0.pathPrefix || request.path.hasPrefix($0.pathPrefix + "/") }),
              let upstream = upstreams[provider] else {
            respond(client, status: "404 Not Found", message: "Redact proxy: only /openai/… and /anthropic/… are proxied")
            return
        }

        // The placeholder can arrive as a bearer token or as x-api-key (Anthropic).
        let lower = request.headers.map { ($0.0.lowercased(), $0.1) }
        let bearer = lower.first { $0.0 == "authorization" }?.1
        let token = (bearer?.lowercased().hasPrefix("bearer ") == true ? String(bearer!.dropFirst(7)) : nil)
            ?? lower.first { $0.0 == "x-api-key" }?.1
        guard let token, let session = session(for: token.trimmingCharacters(in: .whitespaces), provider: provider) else {
            respond(client, status: "401 Unauthorized",
                    message: "Redact proxy: unknown or expired session. Run the command through `redact run` again.")
            return
        }

        var path = String(request.path.dropFirst(provider.pathPrefix.count))
        if !path.hasPrefix("/") { path = "/" + path }
        var outgoing = "\(request.method) \(path) HTTP/1.1\r\n"
        for (name, value) in request.headers where !Self.droppedHeaders.contains(name.lowercased()) {
            outgoing += "\(name): \(value)\r\n"
        }
        outgoing += "Host: \(upstream.host)\r\n"
        switch provider {
        case .openai: outgoing += "Authorization: Bearer \(session.key)\r\n"
        case .anthropic: outgoing += "x-api-key: \(session.key)\r\n"
        }
        outgoing += "Connection: close\r\n\r\n"
        let head = Data(outgoing.utf8)

        let parameters: NWParameters = upstream.useTLS ? .tls : .tcp
        let server = NWConnection(host: NWEndpoint.Host(upstream.host), port: NWEndpoint.Port(rawValue: upstream.port)!, using: parameters)
        // Handlers all run on `queue` (serial), so this flag needs no further locking.
        let started = Box(false)
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready where !started.value:
                started.value = true
                var first = head
                first.append(rest)
                server.send(content: first, completion: .contentProcessed { _ in })
                self.pipe(from: client, to: server, closeTargetOnEnd: false)
                self.pipe(from: server, to: client, closeTargetOnEnd: true, alsoCancel: server)
            case .failed, .waiting:
                if !started.value {
                    started.value = true
                    server.cancel()
                    self.respond(client, status: "502 Bad Gateway", message: "Redact proxy: couldn't reach \(upstream.host)")
                }
            default:
                break
            }
        }
        server.start(queue: queue)
    }

    /// Copies bytes until `source` ends. When `closeTargetOnEnd`, the target (and `alsoCancel`) are closed after.
    private func pipe(from source: NWConnection, to target: NWConnection, closeTargetOnEnd: Bool, alsoCancel: NWConnection? = nil) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            let finish = {
                guard closeTargetOnEnd else { return }
                target.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    target.cancel()
                    alsoCancel?.cancel()
                })
            }
            if let data, !data.isEmpty {
                target.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { target.cancel(); source.cancel(); alsoCancel?.cancel(); return }
                    if isComplete || error != nil { finish() } else { self?.pipe(from: source, to: target, closeTargetOnEnd: closeTargetOnEnd, alsoCancel: alsoCancel) }
                })
            } else if isComplete || error != nil {
                finish()
            } else {
                self?.pipe(from: source, to: target, closeTargetOnEnd: closeTargetOnEnd, alsoCancel: alsoCancel)
            }
        }
    }

    private func respond(_ client: NWConnection, status: String, message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": ["type": "redact_proxy", "message": message]])) ?? Data()
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        client.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            client.cancel()
        })
    }
}

/// Mutable box for state shared between callbacks that all run on one serial queue.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
