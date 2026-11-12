import Foundation
import Testing
@testable import RedactCore

private func path(length: Int) -> String {
    let base = "/tmp/redact-test-"
    return base + String(repeating: "x", count: length - base.utf8.count)
}

@Test func socketAddressAcceptsLongestValidPath() throws {
    let longest = path(length: SocketIO.maxPathLength)
    let address = try SocketIO.address(longest)
    let stored = withUnsafeBytes(of: address.sun_path) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    #expect(stored == longest)
}

@Test func socketAddressRejectsPathsThatWouldBeTruncated() {
    let tooLong = path(length: SocketIO.maxPathLength + 1)
    #expect(throws: BrokerError.self) { try SocketIO.address(tooLong) }
}

@Test func serverAndClientRefuseOverlongSocketPath() {
    let tooLong = path(length: SocketIO.maxPathLength + 20)
    let server = BrokerServer(path: tooLong) { _, _ in BrokerResponse(ok: true) }
    #expect(throws: BrokerError.self) { try server.start() }
    #expect(throws: BrokerError.self) { try BrokerClient.send(BrokerRequest(op: .status), socketPath: tooLong) }
    // Nothing was created at the truncated path.
    #expect(!FileManager.default.fileExists(atPath: String(tooLong.prefix(SocketIO.maxPathLength))))
}
