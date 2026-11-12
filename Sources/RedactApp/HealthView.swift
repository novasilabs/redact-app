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
        VStack(alignment: .leading, spacing: 0) {
            optionsPanel
            Divider()
            results
        }
        .navigationTitle("Health")
        .onReceive(NotificationCenter.default.publisher(for: .redactDevSelectFirst)) { _ in
            if findings == nil { scan() }
        }
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Health").font(.title2.bold())
            Text("Looks for your vault's values and well-known key formats where they shouldn't be. Nothing leaves this Mac.")
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Toggle("Project folders (\(vault.data.projects.count))", isOn: $includeProjects)
                Toggle("…and their git history", isOn: $includeGitHistory).disabled(!includeProjects)
                Toggle(".env files", isOn: $includeEnvFiles).disabled(!includeProjects)
                    .help("Env files are expected to contain secrets until you import and delete them.")
            }
            HStack(spacing: 18) {
                Toggle("Shell history", isOn: $includeShell)
                Toggle("AI transcripts (Claude Code, Codex)", isOn: $includeAI)
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button(scanning ? "Scanning…" : "Scan now") { scan() }
                    .keyboardShortcut("r")
                    .disabled(scanning)
            }
        }
        .padding(20)
    }

    @ViewBuilder private var results: some View {
        if let findings {
            if findings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").font(.system(size: 40)).foregroundStyle(.green)
                    Text("No leaks found").font(.title3)
                    if let scannedAt {
                        Text("Scanned \(scannedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                findingsList(findings)
            }
        } else {
            Text("Run a scan to see where secrets have leaked.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func findingsList(_ findings: [SecretScanner.Finding]) -> some View {
        let groups = grouped
        return List {
            ForEach(groups, id: \.source) { group in
                SwiftUI.Section {
                    ForEach(group.findings, id: \.self) { finding in FindingRow(finding: finding) }
                } header: {
                    GroupHeader(source: group.source)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("\(findings.count) finding\(findings.count == 1 ? "" : "s") in \(groups.count) place\(groups.count == 1 ? "" : "s"). A leaked key should be rotated: replace it at the provider, then use Keys → Replace value.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isValue ? "key.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isValue ? Color.red : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(finding.name) · line \(finding.line)").font(.callout.weight(.medium))
                Text(finding.preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

private struct GroupHeader: View {
    let source: String

    var body: some View {
        HStack {
            Text(abbreviate(source)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            if FileManager.default.fileExists(atPath: source) {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(source, inFileViewerRootedAtPath: "") }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}
