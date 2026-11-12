import Foundation

/// Parser for `.env` / `.dev.vars` files (dotenv syntax).
public enum EnvFile {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var value: String
        public var line: Int
    }

    /// Supports `KEY=value`, `export KEY=value`, comments, single/double/backtick quotes,
    /// multi-line double-quoted values and `\n` escapes in double quotes. No variable expansion.
    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let lineNumber = index + 1
            var line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard isValidName(name) else { continue }
            var raw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            if let quote = raw.first, quote == "\"" || quote == "'" || quote == "`" {
                // Gather lines until the closing quote (multi-line values).
                var body = String(raw.dropFirst())
                while closingQuoteIndex(in: body, quote: quote) == nil, index < lines.count {
                    body += "\n" + lines[index]
                    index += 1
                }
                if let close = closingQuoteIndex(in: body, quote: quote) {
                    body = String(body[..<close])
                }
                raw = quote == "\"" ? unescape(body) : body
            } else if let hash = raw.range(of: " #") {
                raw = raw[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            entries.append(Entry(name: name, value: raw, line: lineNumber))
        }
        return entries
    }

    static func closingQuoteIndex(in text: String, quote: Character) -> String.Index? {
        var escaped = false
        for i in text.indices {
            let c = text[i]
            if escaped { escaped = false; continue }
            if c == "\\" && quote == "\"" { escaped = true; continue }
            if c == quote { return i }
        }
        return nil
    }

    static func unescape(_ text: String) -> String {
        var output = ""
        var escaped = false
        for c in text {
            if escaped {
                switch c {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                default: output.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                output.append(c)
            }
        }
        return output
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.letters.union(["_"]).contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(["_", "."]).contains($0) }
    }

    /// Serialize for tools that insist on a file. Values are always double-quoted and escaped.
    public static func serialize(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { name, value in
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\(name)=\"\(escaped)\""
        }.joined(separator: "\n") + "\n"
    }
}

/// Finds env files inside a project folder (including nested apps in monorepos).
public enum ProjectScanner {
    public struct Found: Equatable, Sendable {
        public var path: String          // absolute
        public var relativePath: String  // relative to the project root
        public var environment: String?  // nil for example/template files
        public var isExample: Bool
    }

    static let skippedDirectories: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", ".next", ".wrangler", ".vercel",
        ".turbo", ".cache", "vendor", "Pods", "DerivedData", ".venv", "venv", "__pycache__", "coverage",
    ]

    /// `excluding`: absolute paths of nested folders that are projects of their own; skipped.
    public static func scan(root: String, maxDepth: Int = 5, excluding: Set<String> = []) -> [Found] {
        let rootURL = URL(fileURLWithPath: WranglerProfiles.realPath(root), isDirectory: true)
        var found: [Found] = []
        func visit(_ url: URL, depth: Int) {
            guard depth <= maxDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if !skippedDirectories.contains(name), !excluding.contains(child.path) { visit(child, depth: depth + 1) }
                    continue
                }
                guard let classified = classify(fileName: name) else { continue }
                let relative = String(child.path.dropFirst(rootURL.path.count + 1))
                found.append(Found(path: child.path, relativePath: relative,
                                   environment: classified.environment, isExample: classified.isExample))
            }
        }
        visit(rootURL, depth: 0)
        return found
    }

    /// Maps a file name to an environment. Returns nil for files that are not env files.
    public static func classify(fileName name: String) -> (environment: String?, isExample: Bool)? {
        let lower = name.lowercased()
        if lower == ".dev.vars" { return ("development", false) }
        if lower.hasPrefix(".dev.vars.") { return (environment(forSuffix: String(lower.dropFirst(10))), false) }
        guard lower == ".env" || lower.hasPrefix(".env.") else { return nil }
        let suffix = lower == ".env" ? "" : String(lower.dropFirst(5))
        if ["example", "sample", "template", "defaults", "dist"].contains(where: { suffix.contains($0) }) {
            return (nil, true)
        }
        return (environment(forSuffix: suffix), false)
    }

    static func environment(forSuffix suffix: String) -> String {
        let parts = suffix.split(separator: ".").map(String.init).filter { $0 != "local" }
        guard let first = parts.first else { return "development" }
        switch first {
        case "development", "dev", "test": return "development"
        case "preview", "staging", "stage", "qa": return "preview"
        case "production", "prod": return "production"
        default: return first
        }
    }
}

/// Compares what is in a project's env files with what the vault already has.
public struct ImportPlan: Sendable {
    public enum Status: String, Sendable { case new, changed, unchanged }

    public struct Row: Identifiable, Sendable, Equatable {
        public var id: String { "\(environment)/\(name)/\(sourceFile)" }
        public var name: String
        public var value: String
        public var environment: String
        public var sourceFile: String
        public var status: Status
        /// A standalone vault item with the same value: offer to link instead of copying.
        public var duplicateOf: UUID?
        public var duplicateName: String?
        /// The same name appears in more than one file for this environment; the later file wins.
        public var shadowed: Bool
        public var selected: Bool
    }

    public var rows: [Row]
    /// Names that an example file lists but no real env file provides, per environment.
    public var missingFromExample: [String: [String]]
    public var files: [ProjectScanner.Found]

    public static func build(root: String, project: Project?, vault: VaultData) throws -> ImportPlan {
        let realRoot = WranglerProfiles.realPath(root)
        let nested = Set(vault.projects.map(\.path).filter { $0.hasPrefix(realRoot + "/") })
        let files = ProjectScanner.scan(root: realRoot, excluding: nested)
        var rows: [Row] = []
        var exampleNames = Set<String>()
        var namesByEnvironment: [String: Set<String>] = [:]

        for file in files {
            let entries = EnvFile.parse(try String(contentsOfFile: file.path, encoding: .utf8))
            if file.isExample {
                exampleNames.formUnion(entries.map(\.name))
                continue
            }
            guard let environment = file.environment else { continue }
            for entry in entries {
                // Later files (e.g. .env.local after .env) win; mark earlier rows as shadowed.
                for i in rows.indices where rows[i].environment == environment && rows[i].name == entry.name {
                    rows[i].shadowed = true
                    rows[i].selected = false
                }
                namesByEnvironment[environment, default: []].insert(entry.name)
                let existing = project.flatMap { p in
                    vault.items.first { $0.kind == .variable && $0.projectID == p.id && $0.environment == environment && $0.name == entry.name }
                }
                let status: Status
                if let existing {
                    status = vault.resolvedValue(of: existing) == entry.value ? .unchanged : .changed
                } else {
                    status = .new
                }
                let duplicate = entry.value.count >= Redactor.minimumSecretLength
                    ? vault.items.first { $0.kind == .apiKey && $0.value == entry.value } : nil
                rows.append(Row(name: entry.name, value: entry.value, environment: environment,
                                sourceFile: file.relativePath, status: status,
                                duplicateOf: duplicate?.id, duplicateName: duplicate?.name,
                                shadowed: false, selected: status != .unchanged))
            }
        }

        var missing: [String: [String]] = [:]
        if !exampleNames.isEmpty {
            for (environment, names) in namesByEnvironment {
                let gaps = exampleNames.subtracting(names).sorted()
                if !gaps.isEmpty { missing[environment] = gaps }
            }
        }
        return ImportPlan(rows: rows, missingFromExample: missing, files: files)
    }

    /// Applies the selected rows to the vault. Returns the IDs of items created or changed (for undo).
    @discardableResult
    public func apply(to vault: inout VaultData, project: Project, linkDuplicates: Bool = true) -> [UUID] {
        var touched: [UUID] = []
        for row in rows where row.selected && !row.shadowed {
            let link = linkDuplicates ? row.duplicateOf : nil
            if let index = vault.items.firstIndex(where: {
                $0.kind == .variable && $0.projectID == project.id && $0.environment == row.environment && $0.name == row.name
            }) {
                vault.items[index].value = link == nil ? row.value : ""
                vault.items[index].linkedItemID = link
                vault.items[index].updatedAt = Date()
                touched.append(vault.items[index].id)
            } else {
                let item = Item(kind: .variable, name: row.name, value: link == nil ? row.value : "",
                                projectID: project.id, environment: row.environment, linkedItemID: link)
                vault.items.append(item)
                touched.append(item.id)
            }
        }
        return touched
    }
}

/// Recognizes common secret formats from their shape, for "paste anything".
public enum SecretDetector {
    public struct Guess: Equatable, Sendable {
        public var provider: String
        public var suggestedName: String
        public var kind: Item.Kind
    }

    static let rules: [(prefix: String, provider: String, name: String)] = [
        ("sk_live_", "Stripe", "STRIPE_SECRET_KEY"),
        ("sk_test_", "Stripe", "STRIPE_SECRET_KEY"),
        ("rk_live_", "Stripe", "STRIPE_RESTRICTED_KEY"),
        ("pk_live_", "Stripe", "STRIPE_PUBLISHABLE_KEY"),
        ("whsec_", "Stripe", "STRIPE_WEBHOOK_SECRET"),
        ("sk-ant-", "Anthropic", "ANTHROPIC_API_KEY"),
        ("sk-proj-", "OpenAI", "OPENAI_API_KEY"),
        ("sk-", "OpenAI", "OPENAI_API_KEY"),
        ("ghp_", "GitHub", "GITHUB_TOKEN"),
        ("github_pat_", "GitHub", "GITHUB_TOKEN"),
        ("gho_", "GitHub", "GITHUB_TOKEN"),
        ("glpat-", "GitLab", "GITLAB_TOKEN"),
        ("xoxb-", "Slack", "SLACK_BOT_TOKEN"),
        ("xoxp-", "Slack", "SLACK_USER_TOKEN"),
        ("AKIA", "AWS", "AWS_ACCESS_KEY_ID"),
        ("re_", "Resend", "RESEND_API_KEY"),
        ("SG.", "SendGrid", "SENDGRID_API_KEY"),
        ("AIza", "Google", "GOOGLE_API_KEY"),
        ("sbp_", "Supabase", "SUPABASE_ACCESS_TOKEN"),
        ("vercel_", "Vercel", "VERCEL_TOKEN"),
        ("npm_", "npm", "NPM_TOKEN"),
        ("hf_", "Hugging Face", "HF_TOKEN"),
        ("postgres://", "Postgres", "DATABASE_URL"),
        ("postgresql://", "Postgres", "DATABASE_URL"),
        ("mysql://", "MySQL", "DATABASE_URL"),
        ("mongodb+srv://", "MongoDB", "MONGODB_URI"),
        ("redis://", "Redis", "REDIS_URL"),
        ("rediss://", "Redis", "REDIS_URL"),
        ("-----BEGIN", "PEM", "PRIVATE_KEY"),
    ]

    public static func guess(_ value: String) -> Guess? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // "NAME=value" pasted from an env file.
        if let eq = trimmed.firstIndex(of: "="), !trimmed.contains("\n") {
            let name = String(trimmed[..<eq])
            if EnvFile.isValidName(name), name == name.uppercased() {
                let inner = guess(String(trimmed[trimmed.index(after: eq)...]))
                return Guess(provider: inner?.provider ?? "Env", suggestedName: name, kind: .apiKey)
            }
        }
        for rule in rules where trimmed.hasPrefix(rule.prefix) {
            return Guess(provider: rule.provider, suggestedName: rule.name, kind: .apiKey)
        }
        let parts = trimmed.split(separator: ".")
        if parts.count == 3, trimmed.hasPrefix("eyJ") {
            return Guess(provider: "JWT", suggestedName: "JWT", kind: .apiKey)
        }
        // Lines of short codes: backup codes.
        let lines = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count >= 4, lines.allSatisfy({ $0.count <= 20 && !$0.contains(" ") }) {
            return Guess(provider: "Backup codes", suggestedName: "Backup codes", kind: .backupCodes)
        }
        // Cloudflare API tokens are 40 chars of [A-Za-z0-9_-].
        if trimmed.count == 40, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return Guess(provider: "Cloudflare (likely)", suggestedName: "CLOUDFLARE_API_TOKEN", kind: .apiKey)
        }
        return nil
    }
}
