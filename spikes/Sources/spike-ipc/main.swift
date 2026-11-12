import Darwin
import Foundation
import RedactCore

// Usage:
//   spike-ipc server <socket-path> [max-connections]   stands in for Redact.app's AgentBroker
//   spike-ipc client <socket-path> <message>           stands in for the `redact` CLI

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: spike-ipc server <sock> [n] | spike-ipc client <sock> <message>")
    exit(64)
}

func makeAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8.prefix(raw.count - 1))
        raw.copyBytes(from: bytes + [0])
    }
    return address
}

func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

let path = args[1]

switch args[0] {
case "server":
    let limit = args.count > 2 ? Int(args[2]) ?? 1 : 1
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = makeAddress(path)
    guard withSockaddr(&address, { bind(fd, $0, $1) }) == 0 else { perror("bind"); exit(1) }
    chmod(path, 0o600) // only this user can connect
    listen(fd, 8)
    print("server listening on \(path)")
    fflush(stdout)
    for _ in 0..<limit {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { perror("accept"); continue }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(client, &buffer, buffer.count)
        let message = String(decoding: buffer.prefix(max(0, n)), as: UTF8.self)
        do {
            let peer = try PeerIdentity.of(socket: client)
            print("--- request: \(message)\n\(peer)")
            let reply = "approved-for-pid-\(peer.pid) (agent: \(peer.agentGuess ?? "none"))\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
        } catch {
            print("peer check failed: \(error)")
        }
        fflush(stdout)
        close(client)
    }
    close(fd)
    unlink(path)

case "client":
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = makeAddress(path)
    guard withSockaddr(&address, { connect(fd, $0, $1) }) == 0 else { perror("connect"); exit(1) }
    let message = args.count > 2 ? args[2] : "hello"
    _ = message.withCString { write(fd, $0, strlen($0)) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buffer, buffer.count)
    print("client got: \(String(decoding: buffer.prefix(max(0, n)), as: UTF8.self))", terminator: "")
    close(fd)

default:
    print("unknown mode")
    exit(64)
}
