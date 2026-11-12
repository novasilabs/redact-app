import Darwin
import Foundation
import Security

/// Who is on the other end of a Unix domain socket, and which processes launched it.
public struct PeerIdentity: Codable, Sendable, CustomStringConvertible {
    public struct Ancestor: Codable, Sendable {
        public var pid: Int32
        public var path: String
    }

    public var pid: Int32
    public var uid: UInt32
    public var path: String
    public var signingIdentifier: String?
    public var teamIdentifier: String?
    public var signatureValid: Bool
    public var ancestors: [Ancestor]

    /// Best-effort guess at which AI agent (if any) launched the peer.
    public var agentGuess: String? { Self.agent(in: ancestors) }

    /// The AI agent among a process's ancestors, if any.
    public static func agent(in ancestors: [Ancestor]) -> String? {
        let known: [(String, String)] = [
            ("claude", "Claude Code"), ("Claude.app", "Claude desktop"), ("Cursor", "Cursor"),
            ("codex", "Codex"), ("Windsurf", "Windsurf"), ("gemini", "Gemini CLI"), ("Zed", "Zed"),
        ]
        for ancestor in ancestors {
            let name = (ancestor.path as NSString).lastPathComponent
            for (needle, label) in known where name.contains(needle) || ancestor.path.contains("/\(needle)") { return label }
        }
        return nil
    }

    /// The AI agent among the current process's ancestors, if any.
    public static var agentInCurrentProcessTree: String? {
        agent(in: ancestors(of: getpid()))
    }

    public var description: String {
        let chain = ancestors.map { "\($0.pid):\(($0.path as NSString).lastPathComponent)" }.joined(separator: " ← ")
        return """
        pid=\(pid) uid=\(uid) path=\(path)
        signing id=\(signingIdentifier ?? "-") team=\(teamIdentifier ?? "-") valid=\(signatureValid)
        ancestors: \(chain)
        agent guess: \(agentGuess ?? "none")
        """
    }

    /// Reads the peer's audit token from a connected Unix socket (immune to PID reuse for the code check).
    public static func of(socket fd: Int32) throws -> PeerIdentity {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
        }
        let pid = Int32(bitPattern: token.val.5)
        let uid = token.val.1

        var signingIdentifier: String?
        var teamIdentifier: String?
        var valid = false
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
           let code {
            valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
                var info: CFDictionary?
                if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                   let dict = info as? [String: Any] {
                    signingIdentifier = dict[kSecCodeInfoIdentifier as String] as? String
                    teamIdentifier = dict[kSecCodeInfoTeamIdentifier as String] as? String
                }
            }
        }

        return PeerIdentity(
            pid: pid, uid: uid, path: Self.path(of: pid) ?? "?",
            signingIdentifier: signingIdentifier, teamIdentifier: teamIdentifier,
            signatureValid: valid, ancestors: Self.ancestors(of: pid)
        )
    }

    static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    static func ancestors(of pid: Int32) -> [Ancestor] {
        var result: [Ancestor] = []
        var current = parent(of: pid)
        while let p = current, result.count < 20 {
            result.append(Ancestor(pid: p, path: path(of: p) ?? "?"))
            current = parent(of: p)
        }
        return result
    }
}
