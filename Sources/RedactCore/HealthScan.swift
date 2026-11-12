import Foundation

public struct ScanOptions: Codable, Sendable, Equatable {
    /// Files or folders to scan (working tree).
    public var paths: [String]
    /// Also scan added lines in the git history of each path that is a repository.
    public var gitHistory: Bool
    public var shellHistory: Bool
    /// Claude Code and Codex transcripts.
    public var aiLogs: Bool
    /// Scan this text instead of files (pre-commit: the staged diff).
    public var text: String?
    public var textSource: String?
    /// Don't scan env files themselves (they are expected to hold secrets until imported).
    public var skipEnvFiles: Bool

    public init(paths: [String] = [], gitHistory: Bool = false, shellHistory: Bool = false, aiLogs: Bool = false,
                text: String? = nil, textSource: String? = nil, skipEnvFiles: Bool = false) {
        self.paths = paths
        self.gitHistory = gitHistory
        self.shellHistory = shellHistory
        self.aiLogs = aiLogs
        self.text = text
        self.textSource = textSource
        self.skipEnvFiles = skipEnvFiles
    }
}

/// Health scan: where have secrets leaked? (PRD §6.6)
public enum HealthScan {
    public static let findingLimit = 2000

    public static var shellHistoryFiles: [String] {
        let home = NSHomeDirectory()
        return [home + "/.zsh_history", home + "/.bash_history", home + "/.local/share/fish/fish_history"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    public static var aiLogFolders: [String] {
        let home = NSHomeDirectory()
        return [home + "/.claude/projects", home + "/.codex/sessions", home + "/.gemini/tmp"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    public static func run(_ options: ScanOptions, secrets: [String: String]) -> [SecretScanner.Finding] {
        let scanner = SecretScanner(secrets: secrets)
        var findings: [SecretScanner.Finding] = []
        func add(_ new: [SecretScanner.Finding]) {
            findings += new.prefix(max(0, findingLimit - findings.count))
        }

        if let text = options.text {
            add(scanDiff(text, scanner: scanner, fallbackSource: options.textSource ?? "input"))
            return findings
        }
        for path in Self.outermost(options.paths) {
            add(scanner.scan(path: path, includeEnvFiles: !options.skipEnvFiles))
            if options.gitHistory, isGitRepository(path) { add(scanGitHistory(path, scanner: scanner)) }
        }
        if options.shellHistory {
            for file in shellHistoryFiles { add(scanner.scanFile(file, maxFileSize: 50_000_000)) }
        }
        if options.aiLogs {
            for folder in aiLogFolders { add(scanner.scan(path: folder, maxFileSize: 200_000_000)) }
        }
        return findings
    }

    /// Drops paths inside other paths in the list (nested projects), so files aren't scanned twice.
    static func outermost(_ paths: [String]) -> [String] {
        let real = Array(Set(paths.map { WranglerProfiles.realPath($0) })).sorted()
        return real.filter { path in !real.contains { $0 != path && path.hasPrefix($0 + "/") } }
    }

    static func isGitRepository(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    /// Scans a unified diff (`git diff`, `git log -p`): only added lines, with real file/line numbers.
    public static func scanDiff(_ diff: String, scanner: SecretScanner, fallbackSource: String) -> [SecretScanner.Finding] {
        var parser = DiffParser(fallbackSource: fallbackSource)
        var findings: [SecretScanner.Finding] = []
        diff.enumerateLines { line, stop in
            if let added = parser.consume(line) {
                findings += scanner.scan(line: added.text, source: added.source, lineNumber: added.line)
                if findings.count >= findingLimit { stop = true }
            }
        }
        return findings
    }

    /// Streams `git log -p` so large histories don't have to fit in memory.
    static func scanGitHistory(_ repo: String, scanner: SecretScanner) -> [SecretScanner.Finding] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo, "log", "-p", "--all", "--no-color", "--no-ext-diff", "-U0", "--format=commit %h"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }

        var parser = DiffParser(fallbackSource: repo)
        var findings: [SecretScanner.Finding] = []
        var buffer = Data()
        let reader = pipe.fileHandleForReading
        while findings.count < findingLimit {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if lineData.count > 100_000 { continue }
                let line = String(decoding: lineData, as: UTF8.self)
                if let added = parser.consume(line) {
                    findings += scanner.scan(line: added.text, source: "git \(added.commit ?? "") \(added.source)", lineNumber: added.line)
                }
            }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        // Each leaked secret usually appears once per commit that touched it; keep the oldest occurrence per file+name.
        var seen = Set<String>()
        return findings.reversed().filter { seen.insert("\($0.name)|\($0.source.split(separator: " ").last ?? "")").inserted }.reversed()
    }
}

/// Minimal unified-diff reader: tracks commit, file and new-side line numbers; yields added lines.
struct DiffParser {
    struct Added { let text: String; let source: String; let line: Int; let commit: String? }

    let fallbackSource: String
    private var commit: String?
    private var file: String?
    private var nextLine = 0

    init(fallbackSource: String) {
        self.fallbackSource = fallbackSource
    }

    mutating func consume(_ line: String) -> Added? {
        if line.hasPrefix("commit ") {
            commit = String(line.dropFirst(7))
            return nil
        }
        if line.hasPrefix("+++ ") {
            let path = String(line.dropFirst(4))
            file = path == "/dev/null" ? nil : (path.hasPrefix("b/") ? String(path.dropFirst(2)) : path)
            return nil
        }
        if line.hasPrefix("--- ") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return nil }
        if line.hasPrefix("@@") {
            // @@ -a,b +c,d @@
            if let plus = line.range(of: " +") {
                let numbers = line[plus.upperBound...].prefix { $0.isNumber }
                nextLine = Int(numbers) ?? 0
            }
            return nil
        }
        if line.hasPrefix("+") {
            defer { nextLine += 1 }
            return Added(text: String(line.dropFirst()), source: file ?? fallbackSource, line: nextLine, commit: commit)
        }
        if line.hasPrefix(" ") { nextLine += 1 }
        return nil
    }
}
