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
