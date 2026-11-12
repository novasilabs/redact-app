import Foundation

/// Finds secrets in text: known key formats (no vault needed) and exact vault values.
///
/// Findings never contain the secret itself, only where it is and what it looks like.
public struct SecretScanner {
    public struct Finding: Codable, Sendable, Equatable, Hashable {
        public enum Kind: String, Codable, Sendable { case vaultValue, knownFormat }
        public var kind: Kind
        /// Vault variable/key name, or the format name ("GitHub token").
        public var name: String
        public var source: String    // file path, "git:<commit> <path>", "shell history", …
        public var line: Int
        /// The line with the secret replaced by `[redact:…]`, trimmed to 160 chars.
        public var preview: String

        public init(kind: Kind, name: String, source: String, line: Int, preview: String) {
            self.kind = kind
            self.name = name
            self.source = source
            self.line = line
            self.preview = preview
        }
    }

    struct Rule: Sendable {
        let name: String
        let regex: NSRegularExpression
    }

    /// Known formats with low false-positive rates. Order: most specific first.
    static let rules: [Rule] = [
        ("Private key", #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY-----"#),
        ("AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("GitHub token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"#),
        ("GitHub token", #"\bgithub_pat_[A-Za-z0-9_]{60,}\b"#),
        ("GitLab token", #"\bglpat-[A-Za-z0-9_\-]{20,}\b"#),
        ("Anthropic key", #"\bsk-ant-[A-Za-z0-9_\-]{32,}"#),
        ("OpenAI key", #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{32,}"#),
        ("Stripe secret key", #"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}\b"#),
        ("Stripe webhook secret", #"\bwhsec_[A-Za-z0-9]{24,}\b"#),
        ("Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        ("Slack webhook", #"https://hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("Supabase token", #"\bsbp_[a-f0-9]{40}\b"#),
        ("npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
        ("Hugging Face token", #"\bhf_[A-Za-z0-9]{34,}\b"#),
        ("SendGrid key", #"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#),
        ("Database URL with password", #"\b(?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|rediss)://[^\s:/@]+:[^\s@/]{3,}@[^\s]+"#),
    ].map { Rule(name: $0.0, regex: try! NSRegularExpression(pattern: $0.1)) }

    /// Vault values shorter than this are not scanned for (too many false hits, and a guessing oracle).
    public static let minimumValueLength = 12

    private let redactor: Redactor?
    private let valueNames: [String: String] // value → name, for reporting

    /// `secrets`: name → value. Pass an empty dictionary for pattern-only scanning.
    public init(secrets: [String: String]) {
        let usable = secrets.filter { $0.value.utf8.count >= Self.minimumValueLength }
        redactor = usable.isEmpty ? nil : Redactor(secrets: usable)
        var names: [String: String] = [:]
        for (name, value) in usable.sorted(by: { $0.key < $1.key }) where names[value] == nil { names[value] = name }
        valueNames = names
    }

    /// Scans text line by line.
    public func scan(text: String, source: String, firstLine: Int = 1) -> [Finding] {
        var findings: [Finding] = []
        var lineNumber = firstLine - 1
        text.enumerateLines { line, _ in
            lineNumber += 1
            findings += self.scan(line: line, source: source, lineNumber: lineNumber)
        }
        return findings
    }

    public func scan(line: String, source: String, lineNumber: Int) -> [Finding] {
        guard !line.isEmpty, line.utf8.count < 100_000 else { return [] }
        var findings: [Finding] = []
        var masked = line

        // Vault values first: they name the exact secret.
        if let redactor {
            let output = String(decoding: redactor.feed(Array(line.utf8)) + redactor.finish(), as: UTF8.self)
            if output != line {
                masked = output
                let names = Self.placeholderNames(in: output)
                for name in Set(names).sorted() {
                    findings.append(Finding(kind: .vaultValue, name: name, source: source, line: lineNumber, preview: ""))
                }
            }
        }

        // Known formats, on what is left after vault values were masked.
        var seenRules = Set<String>()
        for rule in Self.rules {
            // Recompute: earlier replacements change the line's length.
            let matches = rule.regex.matches(in: masked, range: NSRange(masked.startIndex..., in: masked))
            guard !matches.isEmpty, !seenRules.contains(rule.name) else { continue }
            seenRules.insert(rule.name)
            for match in matches.reversed() {
                if let r = Range(match.range, in: masked) { masked.replaceSubrange(r, with: "[redact:\(rule.name)]") }
            }
            findings.append(Finding(kind: .knownFormat, name: rule.name, source: source, line: lineNumber, preview: ""))
        }

        guard !findings.isEmpty else { return [] }
        let preview = Self.trimPreview(masked)
        return findings.map { var f = $0; f.preview = preview; return f }
    }

    static func placeholderNames(in text: String) -> [String] {
        var names: [String] = []
        var rest = text[...]
        while let start = rest.range(of: "[redact:") {
            guard let end = rest[start.upperBound...].firstIndex(of: "]") else { break }
            names.append(String(rest[start.upperBound..<end]))
            rest = rest[rest.index(after: end)...]
        }
        return names
    }

    static func trimPreview(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 160 else { return trimmed }
        // Keep the first placeholder visible.
        if let r = trimmed.range(of: "[redact:") {
            let start = trimmed.index(r.lowerBound, offsetBy: -60, limitedBy: trimmed.startIndex) ?? trimmed.startIndex
            let end = trimmed.index(start, offsetBy: 160, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            return (start > trimmed.startIndex ? "…" : "") + trimmed[start..<end] + (end < trimmed.endIndex ? "…" : "")
        }
        return String(trimmed.prefix(160)) + "…"
    }

    // MARK: - Files

    static let skippedDirectories: Set<String> = ProjectScanner.skippedDirectories.union([".git", ".hg", ".svn"])
    static let skippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "pdf", "zip", "gz", "tgz", "xz", "bz2", "7z",
        "mp3", "mp4", "mov", "wav", "woff", "woff2", "ttf", "otf", "eot", "wasm", "dylib", "so", "a", "o",
        "class", "jar", "pyc", "lock", "sqlite", "db",
    ]

    /// Scans files under `root` (or a single file). Skips dependencies, build output, binaries and
    /// files larger than `maxFileSize`.
    public func scan(path root: String, maxFileSize: Int = 5_000_000, includeEnvFiles: Bool = true) -> [Finding] {
        var findings: [Finding] = []
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return scanFile(root, maxFileSize: maxFileSize) }

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey], options: []) else { return [] }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if Self.skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if Self.skippedExtensions.contains(url.pathExtension.lowercased()) { continue }
            if !includeEnvFiles, ProjectScanner.classify(fileName: url.lastPathComponent) != nil { continue }
            if let size = values?.fileSize, size > maxFileSize { continue }
            findings += scanFile(url.path, maxFileSize: maxFileSize)
        }
        return findings
    }

    public func scanFile(_ path: String, maxFileSize: Int = 5_000_000) -> [Finding] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileSize), !data.isEmpty else { return [] }
        // Binary check: NUL byte in the first 8 KB.
        if data.prefix(8192).contains(0) { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return scan(text: text, source: path)
    }
}
