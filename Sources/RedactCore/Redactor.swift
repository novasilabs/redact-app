import Foundation

/// Streaming byte-level redactor.
///
/// Replaces every occurrence of a secret value (and its common encodings) with
/// `[redact:NAME]`. Safe across chunk boundaries: it holds back the last
/// `maxPatternLength - 1` bytes until more input arrives or `finish()` is called.
public final class Redactor {
    public struct Pattern {
        public let bytes: [UInt8]
        public let name: String
        public let variant: String
    }

    /// Values shorter than this are not masked (too likely to collide with normal output).
    public static let minimumSecretLength = 6

    public private(set) var patterns: [Pattern] = []
    /// Names that were skipped because the value is too short to mask safely.
    public private(set) var skipped: [String] = []
    public private(set) var matchCount = 0

    /// Patterns bucketed by their first two bytes (all patterns are >= 6 bytes long).
    private var byPrefix: [[Int]] = Array(repeating: [], count: 65536)
    private var hasPrefix: [Bool] = Array(repeating: false, count: 65536)
    private var patternStorage: [UnsafeMutablePointer<UInt8>] = []
    private var lengths: [Int] = []
    private var placeholders: [[UInt8]] = []
    private var maxLength = 0
    private var pending: [UInt8] = []

    deinit {
        for (pointer, length) in zip(patternStorage, lengths) {
            // Zero secret copies before freeing.
            memset_s(pointer, length, 0, length)
            pointer.deallocate()
        }
    }

    public init(secrets: [String: String]) {
        var seen = Set<[UInt8]>()
        // Sort by name so duplicate values always resolve to the same name.
        for (name, value) in secrets.sorted(by: { $0.key < $1.key }) {
            guard value.utf8.count >= Self.minimumSecretLength else {
                skipped.append(name)
                continue
            }
            for (variant, encoded) in Self.variants(of: value) where encoded.count >= Self.minimumSecretLength {
                let bytes = Array(encoded.utf8)
                guard seen.insert(bytes).inserted else { continue }
                patterns.append(Pattern(bytes: bytes, name: name, variant: variant))
            }
        }
        for (index, pattern) in patterns.enumerated() {
            let key = Int(pattern.bytes[0]) << 8 | Int(pattern.bytes[1])
            byPrefix[key].append(index)
            hasPrefix[key] = true
            maxLength = max(maxLength, pattern.bytes.count)
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: pattern.bytes.count)
            pointer.initialize(from: pattern.bytes, count: pattern.bytes.count)
            patternStorage.append(pointer)
            lengths.append(pattern.bytes.count)
            placeholders.append(Array("[redact:\(pattern.name)]".utf8))
        }
        // Longest first, so a value that contains another value is masked as a whole.
        for key in 0..<65536 where hasPrefix[key] {
            byPrefix[key].sort { patterns[$0].bytes.count > patterns[$1].bytes.count }
        }
    }

    static func variants(of value: String) -> [(String, String)] {
        let data = Data(value.utf8)
        let base64 = data.base64EncodedString()
        let base64NoPad = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let base64URL = base64NoPad
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let percent = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
        let json: String = {
            guard let encoded = try? JSONEncoder().encode(value),
                  let string = String(data: encoded, encoding: .utf8) else { return value }
            return String(string.dropFirst().dropLast())
        }()
        return [
            ("raw", value),
            ("base64", base64),
            ("base64-nopad", base64NoPad),
            ("base64url", base64URL),
            ("percent", percent),
            ("json", json),
        ]
    }

    /// Feed a chunk; returns the bytes that are safe to emit now.
    public func feed(_ chunk: some Sequence<UInt8>) -> [UInt8] {
        pending.append(contentsOf: chunk)
        return drain(final: false)
    }

    /// Flush everything that is still held back.
    public func finish() -> [UInt8] {
        drain(final: true)
    }

    private func drain(final: Bool) -> [UInt8] {
        guard maxLength > 0 else {
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        let count = pending.count
        // Positions below `safeEnd` are guaranteed to have every pattern fully in the buffer.
        let safeEnd = final ? count : max(0, count - (maxLength - 1))
        var output: [UInt8] = []
        output.reserveCapacity(count + 64)
        var i = 0
        pending.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            var runStart = 0
            while i < safeEnd {
                // Fast path: most positions cannot start any pattern.
                guard i + 1 < count else { i += 1; continue }
                let key = Int(base[i]) << 8 | Int(base[i + 1])
                guard hasPrefix[key] else { i += 1; continue }
                var matchedIndex = -1
                for index in byPrefix[key] {
                    let length = lengths[index]
                    if i + length <= count, memcmp(base + i, patternStorage[index], length) == 0 {
                        matchedIndex = index
                        break
                    }
                }
                if matchedIndex < 0 { i += 1; continue }
                output.append(contentsOf: UnsafeBufferPointer(start: base + runStart, count: i - runStart))
                output.append(contentsOf: placeholders[matchedIndex])
                matchCount += 1
                i += lengths[matchedIndex]
                runStart = i
            }
            let emitEnd = max(i, runStart)
            output.append(contentsOf: UnsafeBufferPointer(start: base + runStart, count: emitEnd - runStart))
            i = emitEnd
        }
        pending.removeSubrange(0..<min(i, count))
        return output
    }
}
