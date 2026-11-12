import Foundation
import Network
import Testing
@testable import RedactCore

/// Plain-HTTP server standing in for api.openai.com / api.anthropic.com. It replies with the request
/// head and body it received, sent in three chunks with pauses (like a streaming response).
final class FakeUpstream: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake-upstream")
    var port: UInt16 { listener.port!.rawValue }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            FakeUpstream.read(connection, Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    static func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return read(connection, buffer) }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard buffer.count - end.upperBound >= length else { return read(connection, buffer) }
            let body = String(decoding: buffer[end.upperBound...], as: UTF8.self)
            let chunks = ["HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n", "HEAD<<\(head)>>\n", "BODY<<\(body)>>\n"]
            send(connection, chunks)
        }
    }

    static func send(_ connection: NWConnection, _ chunks: [String]) {
        guard let first = chunks.first else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: Data(first.utf8), completion: .contentProcessed { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { send(connection, Array(chunks.dropFirst())) }
        })
    }
}

private func call(_ url: String, headers: [String: String], body: String) async throws -> (Int, String) {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
}

@Test func proxySwapsPlaceholderForRealKeyOpenAI() async throws {
    let upstream = try FakeUpstream()
    let proxy = LLMProxy(upstreams: [.openai: .init(host: "127.0.0.1", port: upstream.port, useTLS: false)])
    let port = try proxy.start()
    let placeholder = proxy.createSession(provider: .openai, key: "sk-real-openai-key", label: "test")
    #expect(placeholder.hasPrefix(LLMProxy.placeholderPrefix))

    let (status, text) = try await call(LLMProxy.Provider.openai.baseURL(port: port) + "/chat/completions",
                                        headers: ["Authorization": "Bearer \(placeholder)", "Content-Type": "application/json"],
                                        body: #"{"model":"x","stream":true}"#)
    #expect(status == 200)
    #expect(text.contains("POST /v1/chat/completions HTTP/1.1"))
    #expect(text.contains("Authorization: Bearer sk-real-openai-key"))
    #expect(!text.contains(placeholder))
    #expect(text.contains("Host: 127.0.0.1"))
    #expect(text.contains("Connection: close"))
    #expect(text.contains(#"BODY<<{"model":"x","stream":true}>>"#))
    #expect(proxy.requestCount(label: "test") == 1)
    proxy.stop()
}

@Test func proxyUsesXApiKeyForAnthropic() async throws {
    let upstream = try FakeUpstream()
    let proxy = LLMProxy(upstreams: [.anthropic: .init(host: "127.0.0.1", port: upstream.port, useTLS: false)])
    let port = try proxy.start()
    let placeholder = proxy.createSession(provider: .anthropic, key: "sk-ant-real", label: "test")
    let (status, text) = try await call(LLMProxy.Provider.anthropic.baseURL(port: port) + "/v1/messages",
                                        headers: ["x-api-key": placeholder, "anthropic-version": "2023-06-01"], body: "{}")
    #expect(status == 200)
    #expect(text.contains("POST /v1/messages HTTP/1.1"))
    #expect(text.contains("x-api-key: sk-ant-real"))
    #expect(text.contains("anthropic-version: 2023-06-01"))
    #expect(!text.contains(placeholder))
    proxy.stop()
}

@Test func proxyRejectsUnknownExpiredOrWrongProviderTokens() async throws {
    let upstream = try FakeUpstream()
    let proxy = LLMProxy(upstreams: [
        .openai: .init(host: "127.0.0.1", port: upstream.port, useTLS: false),
        .anthropic: .init(host: "127.0.0.1", port: upstream.port, useTLS: false),
    ])
    let port = try proxy.start()
    let base = LLMProxy.Provider.openai.baseURL(port: port)

    let unknown = try await call(base + "/models", headers: ["Authorization": "Bearer redact-proxy-nope"], body: "")
    #expect(unknown.0 == 401)
    #expect(unknown.1.contains("unknown or expired"))

    let anthropicToken = proxy.createSession(provider: .anthropic, key: "sk-ant-real", label: "t")
    let wrongProvider = try await call(base + "/models", headers: ["Authorization": "Bearer \(anthropicToken)"], body: "")
    #expect(wrongProvider.0 == 401)

    let expired = proxy.createSession(provider: .openai, key: "sk-real", label: "t", ttl: -1)
    #expect(try await call(base + "/models", headers: ["Authorization": "Bearer \(expired)"], body: "").0 == 401)

    let ended = proxy.createSession(provider: .openai, key: "sk-real", label: "t")
    proxy.endSessions([ended])
    #expect(try await call(base + "/models", headers: ["Authorization": "Bearer \(ended)"], body: "").0 == 401)

    let other = try await call("http://127.0.0.1:\(port)/evil.example.com/steal", headers: [:], body: "")
    #expect(other.0 == 404)
    proxy.stop()
}
