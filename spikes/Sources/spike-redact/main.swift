import Foundation
import RedactCore

// Usage:
//   spike-redact --mask NAME1,NAME2 -- <cmd> [args...]   run cmd, mask values of the named env vars in its output
//   spike-redact bench [megabytes]                        throughput benchmark

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "bench" {
    let megabytes = args.count > 1 ? Int(args[1]) ?? 100 : 100
    var secrets: [String: String] = [:]
    for n in 0..<200 { secrets["KEY_\(n)"] = "sk_test_\(n)_" + UUID().uuidString }
    let redactor = Redactor(secrets: secrets)
    let line = Array("2026-11-12T10:00:00Z INFO request handled path=/api/v1/users status=200 duration=12ms\n".utf8)
    let secretLine = Array("Authorization: Bearer \(secrets["KEY_7"]!)\n".utf8)
    var chunk: [UInt8] = []
    while chunk.count < 64 * 1024 { chunk += chunk.count % 4096 < line.count ? secretLine : line }
    let total = megabytes * 1024 * 1024
    let start = Date()
    var processed = 0
    var emitted = 0
    while processed < total {
        emitted += redactor.feed(chunk).count
        processed += chunk.count
    }
    emitted += redactor.finish().count
    let seconds = Date().timeIntervalSince(start)
    print(String(format: "patterns=%d processed=%d MB in %.2fs → %.0f MB/s, matches=%d",
                 redactor.patterns.count, megabytes, seconds, Double(megabytes) / seconds, redactor.matchCount))
    exit(0)
}

guard let maskIndex = args.firstIndex(of: "--mask"), maskIndex + 1 < args.count,
      let dashIndex = args.firstIndex(of: "--"), dashIndex + 1 < args.count else {
    FileHandle.standardError.write(Data("usage: spike-redact --mask A,B -- cmd args...\n".utf8))
    exit(64)
}

let names = args[maskIndex + 1].split(separator: ",").map(String.init)
let environment = ProcessInfo.processInfo.environment
let secrets = names.reduce(into: [String: String]()) { $0[$1] = environment[$1] }
let command = Array(args[(dashIndex + 1)...])

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = command
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
process.standardOutput = stdoutPipe
process.standardError = stderrPipe

func pump(_ pipe: Pipe, to handle: FileHandle, group: DispatchGroup) {
    group.enter()
    DispatchQueue.global().async {
        let redactor = Redactor(secrets: secrets)
        let reader = pipe.fileHandleForReading
        while true {
            let data = reader.availableData
            if data.isEmpty { break }
            handle.write(Data(redactor.feed(data)))
        }
        handle.write(Data(redactor.finish()))
        group.leave()
    }
}

let group = DispatchGroup()
try process.run()
pump(stdoutPipe, to: .standardOutput, group: group)
pump(stderrPipe, to: .standardError, group: group)
process.waitUntilExit()
group.wait()
exit(process.terminationStatus)
