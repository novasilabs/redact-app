import RedactCore
import SwiftUI

/// Where have secrets leaked? Scans project folders, git history, shell history and AI transcripts.
struct HealthView: View {
    @EnvironmentObject var vault: VaultController
    @State private var includeProjects = true
    @State private var includeGitHistory = false
    // Dev snapshots must never scan (and screenshot) the real shell history or AI transcripts.
    @State private var includeShell = DevSnapshot.directory == nil
    @State private var includeAI = DevSnapshot.directory == nil
    @State private var includeEnvFiles = false
    @State private var scanning = false
    @State private var findings: [SecretScanner.Finding]?
    @State private var scannedAt: Date?

    var grouped: [(source: String, findings: [SecretScanner.Finding])] {
        Dictionary(grouping: findings ?? [], by: \.source)
            .map { ($0.key, $0.value.sorted { $0.line < $1.line }) }
            .sorted { $0.source < $1.source }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                PageHeader(title: "Leak check",
                           subtitle: "Looks for your vault's values and well-known key formats where they shouldn't be. Nothing leaves this Mac.") {
                    Button(action: scan) {
                        Label(scanning ? "Scanning…" : "Scan now", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.primary)
                    .keyboardShortcut("r")
                    .disabled(scanning)
                }
                optionsCard
                results
            }
            .padding(Space.xl)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevSelectFirst)) { _ in
            if findings == nil { scan() }
        }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GroupLabel("Where to look")
            HStack(alignment: .top, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Toggle("Project folders (\(vault.data.projects.count))", isOn: $includeProjects)
                    Toggle("Their git history", isOn: $includeGitHistory).disabled(!includeProjects).padding(.leading, Space.l)
                    Toggle(".env files too", isOn: $includeEnvFiles).disabled(!includeProjects).padding(.leading, Space.l)
                        .help("Env files are expected to contain secrets until you import and delete them.")
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    Toggle("Shell history", isOn: $includeShell)
                    Toggle("AI transcripts (Claude Code, Codex)", isOn: $includeAI)
                }
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)
            .font(TextStyle.body)
            .padding(Space.l)
            .card()
        }
    }

    @ViewBuilder private var results: some View {
        if scanning && findings == nil {
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(TextStyle.body).foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity)
            .padding(Space.xxl)
        } else if let findings {
            if findings.isEmpty {
                EmptyState(symbol: "checkmark.shield", title: "No leaks found",
                           message: scannedAt.map { "Scanned at \($0.formatted(date: .omitted, time: .shortened))." } ?? "")
                    .card()
            } else {
                findingsList(findings)
            }
        } else {
            EmptyState(symbol: "magnifyingglass", title: "Not scanned yet",
                       message: "Run a scan to see whether a key ended up in a file, a commit, your shell history or an AI transcript.")
                .card()
        }
    }

    private func findingsList(_ findings: [SecretScanner.Finding]) -> some View {
        let groups = grouped
        let values = findings.filter { $0.kind == .vaultValue }.count
        return VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Text("\(findings.count) finding\(findings.count == 1 ? "" : "s") in \(groups.count) place\(groups.count == 1 ? "" : "s")")
                    .font(TextStyle.heading).foregroundStyle(Palette.ink)
                if values > 0 { Pill(text: "\(values) from your vault", symbol: "key.fill", tone: .danger) }
                Spacer()
                if let scannedAt { Text("Scanned \(Ago.text(scannedAt))").font(TextStyle.small).foregroundStyle(Palette.ink2) }
            }
            Text("A leaked key should be rotated: replace it at the provider, then use Keys, Replace value.")
                .font(TextStyle.small).foregroundStyle(Palette.ink2)
            ForEach(groups, id: \.source) { group in
                VStack(spacing: 0) {
                    GroupHeader(source: group.source)
                    ForEach(group.findings, id: \.self) { finding in
                        Rule()
                        FindingRow(finding: finding)
                    }
                }
                .card()
            }
        }
    }

    private func scan() {
        let options = ScanOptions(
            paths: includeProjects ? vault.data.projects.map(\.path) : [],
            gitHistory: includeProjects && includeGitHistory,
            shellHistory: includeShell,
            aiLogs: includeAI,
            skipEnvFiles: !includeEnvFiles)
        let secrets = BrokerHandler.scanSecrets(vault.data)
        scanning = true
        vault.touch()
        Task {
            let result = await Task.detached { HealthScan.run(options, secrets: secrets) }.value
            findings = result
            scannedAt = Date()
            scanning = false
        }
    }
}

private struct FindingRow: View {
    let finding: SecretScanner.Finding

    var body: some View {
        let isValue = finding.kind == .vaultValue
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Pill(text: isValue ? "Vault value" : "Key format", symbol: isValue ? "key.fill" : "exclamationmark.triangle.fill",
                 tone: isValue ? .danger : .warning)
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(finding.name).font(TextStyle.monoStrong).foregroundStyle(Palette.ink)
                    Text("line \(finding.line)").font(TextStyle.small).monospacedDigit().foregroundStyle(Palette.ink2)
                }
                Text(finding.preview).font(TextStyle.monoSmall).foregroundStyle(Palette.ink2).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
    }
}

private struct GroupHeader: View {
    let source: String

    var body: some View {
        HStack {
            Label {
                Text(abbreviate(source)).font(TextStyle.mono).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            .labelStyle(TightLabelStyle())
            .foregroundStyle(Palette.ink)
            .help(source)
            Spacer()
            if FileManager.default.fileExists(atPath: source) {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(source, inFileViewerRootedAtPath: "") }
                    .buttonStyle(.quiet)
            }
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.xs)
        .frame(height: 40)
    }
}
