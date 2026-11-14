import Foundation
import Testing
@testable import RedactCore

private func run(_ secrets: [String: String], _ input: String, chunkSizes: [Int]? = nil) -> String {
    let redactor = Redactor(secrets: secrets)
    let bytes = Array(input.utf8)
    var out: [UInt8] = []
    var i = 0
    var k = 0
    while i < bytes.count {
        let size = chunkSizes.map { $0[k % $0.count] } ?? bytes.count
        let end = min(bytes.count, i + max(1, size))
        out += redactor.feed(bytes[i..<end])
        i = end
        k += 1
    }
    out += redactor.finish()
    return String(decoding: out, as: UTF8.self)
}

@Test func masksRawValue() {
    #expect(run(["STRIPE": "sk_live_abc123XYZ"], "key=sk_live_abc123XYZ done") == "key=[redact:STRIPE] done")
}

@Test func masksAcrossEveryChunkBoundary() {
    let secret = "sk_live_abc123XYZ"
    let input = "aaa \(secret) bbb \(secret)"
    let expected = "aaa [redact:S] bbb [redact:S]"
    for size in 1...input.utf8.count {
        #expect(run(["S": secret], input, chunkSizes: [size]) == expected, "chunk size \(size)")
    }
}

@Test func masksEncodedVariants() {
    let secret = "p@ss/word+with=chars&more"
    let b64 = Data(secret.utf8).base64EncodedString()
    let url = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let input = "b64:\(b64) url:\(url) json:\"p@ss\\/word\""
    let output = run(["PW": secret], input)
    #expect(!output.contains(b64))
    #expect(!output.contains(url))
    #expect(output.contains("b64:[redact:PW]"))
    #expect(output.contains("url:[redact:PW]"))
}

@Test func longestMatchWins() {
    let output = run(["SHORT": "abcdef12", "LONG": "abcdef12345678"], "x abcdef12345678 y abcdef12 z")
    #expect(output == "x [redact:LONG] y [redact:SHORT] z")
}

@Test func skipsTooShortValues() {
    let redactor = Redactor(secrets: ["PORT": "3000", "TOKEN": "tok_1234567"])
    #expect(redactor.skipped == ["PORT"])
}

@Test func passesThroughBinaryAndUnicode() {
    let input = "héllo 🌍 \u{1B}[31mred\u{1B}[0m tok_1234567 end"
    #expect(run(["T": "tok_1234567"], input, chunkSizes: [3, 1, 7]) == "héllo 🌍 \u{1B}[31mred\u{1B}[0m [redact:T] end")
}

@Test func randomizedChunkingMatchesOneShot() {
    var rng = SystemRandomNumberGenerator()
    let secrets = (0..<20).reduce(into: [String: String]()) { dict, n in
        dict["K\(n)"] = "secret_\(n)_" + String((0..<Int.random(in: 6...40, using: &rng)).map { _ in "abcdefXYZ0123456789".randomElement()! })
    }
    let values = Array(secrets.values)
    for _ in 0..<200 {
        var text = ""
        for _ in 0..<50 {
            text += Bool.random() ? values.randomElement()! : String(repeating: "lorem ", count: Int.random(in: 0...5))
        }
        let oneShot = run(secrets, text)
        let chunks = (0..<5).map { _ in Int.random(in: 1...64) }
        #expect(run(secrets, text, chunkSizes: chunks) == oneShot)
        for value in values { #expect(!oneShot.contains(value)) }
    }
}

@Test func idleFlushEmitsQuietOutputButNeverPartOfASecret() {
    let redactor = Redactor(secrets: ["TOKEN": "supersecret-123456"])
    func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    // A dev server prints its banner and goes quiet: all of it comes out on the idle flush.
    var out = text(redactor.feed(Array("Local: http://localhost:5173/\n".utf8)))
    out += text(redactor.flushIdle())
    #expect(out == "Local: http://localhost:5173/\n")
    #expect(!redactor.isHolding)

    // Output that stops halfway through a secret: the possible start of it is kept back.
    out = text(redactor.feed(Array("token=supers".utf8))) + text(redactor.flushIdle())
    #expect(out == "token=")
    out += text(redactor.feed(Array("ecret-123456 ok".utf8))) + text(redactor.finish())
    #expect(out == "token=[redact:TOKEN] ok")
}

@Test func idleFlushNeverCutsThroughACompleteSecret() {
    // Review finding: a complete secret ending the buffer, whose last byte starts another secret.
    let redactor = Redactor(secrets: ["A": "abcdef0123s", "B": "sk_live_abcdefgh"])
    var out = String(decoding: redactor.feed(Array("token=abcdef0123s".utf8)) + redactor.flushIdle(), as: UTF8.self)
    out += String(decoding: redactor.finish(), as: UTF8.self)
    #expect(out == "token=[redact:A]")
}

@Test func idleFlushNeverEmitsAPrefixOfASecret() {
    // Property: whatever is printed before more output arrives contains no 2+ byte prefix of a secret
    // that continues in the bytes that follow.
    let secrets = ["A": "abcdef0123s", "B": "sk_live_abcdefgh", "C": "ssh-key-XYZ12345"]
    var generator = SystemRandomNumberGenerator()
    let alphabet = Array("abcdefs0123_klivXYZ-h ".utf8)
    for _ in 0..<300 {
        let redactor = Redactor(secrets: secrets)
        var input: [UInt8] = []
        for _ in 0..<Int.random(in: 1...4, using: &generator) {
            input += (0..<Int.random(in: 0...8, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            input += Array(secrets.values.randomElement(using: &generator)!.utf8)
        }
        let split = Int.random(in: 0...input.count, using: &generator)
        let early = redactor.feed(input[..<split]) + redactor.flushIdle()
        let all = early + redactor.feed(input[split...]) + redactor.finish()
        let text = String(decoding: all, as: UTF8.self)
        for value in secrets.values { #expect(!text.contains(value)) }
        let earlyText = String(decoding: early, as: UTF8.self)
        // The early part, once no more placeholders are added, must not end with a secret's start.
        for value in secrets.values {
            for n in 2..<value.count where earlyText.hasSuffix(String(value.prefix(n))) {
                let rest = String(decoding: Array(input[split...]), as: UTF8.self)
                #expect(!rest.hasPrefix(String(value.dropFirst(n))), "leaked \(n) bytes of a secret before more output")
            }
        }
    }
}

@Test func masksHexLowercasePercentAndMisalignedBase64() {
    let secret = "pa55/word+Secret-9x"
    let redactor = Redactor(secrets: ["DB_PASSWORD": secret])
    func masked(_ text: String) -> String { String(decoding: redactor.feed(Array(text.utf8)) + redactor.finish(), as: UTF8.self) }
    let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
    #expect(!masked("dump: \(hex)").contains(hex))
    #expect(!masked("dump: \(hex.uppercased())").contains(hex.uppercased()))
    #expect(!masked("q=pa55%2fword%2bSecret-9x").contains("pa55%2fword"))
    for user in ["a", "ab", "abc", "admin"] {
        let basic = Data("\(user):\(secret)".utf8).base64EncodedString()
        let out = masked("Authorization: Basic \(basic)")
        #expect(out.contains("[redact:DB_PASSWORD]"), "Basic auth with user \(user)")
    }
}
