import CryptoKit
import RedactCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let redactBackup = UTType(exportedAs: "dev.redact.backup", conformingTo: .data)
}

// MARK: - Backup & restore page

struct BackupView: View {
    @EnvironmentObject var vault: VaultController
    @State private var everything = true
    @State private var projectIDs: Set<UUID> = []
    @State private var itemIDs: Set<UUID> = []
    @State private var identityIDs: Set<UUID> = []
    @State private var includeActivity = true
    @State private var saved: URL?
    @State private var error: String?
    @State private var restoreURL: URL?
    @State private var newRecoveryKey: String?

    private var selection: BackupSelection {
        everything ? .all(vault.data)
            : BackupSelection(projectIDs: projectIDs, itemIDs: itemIDs, identityIDs: identityIDs, includeActivity: includeActivity)
    }

    private var isEmpty: Bool {
        let s = selection
        return s.projectIDs.isEmpty && s.itemIDs.isEmpty && s.identityIDs.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                PageHeader(title: "Backup & restore",
                           subtitle: "A backup is one encrypted `.redact` file. Your Recovery Key opens it, on this Mac or on a new one.")

                exportCard
                restoreCard
                recoveryCard
                movingCard
            }
            .padding(Space.xl)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .sheet(item: Binding(get: { restoreURL.map { ImportTarget(path: $0.path) } }, set: { restoreURL = $0.map { URL(fileURLWithPath: $0.path) } })) { target in
            RestoreSheet(url: URL(fileURLWithPath: target.path), mode: .merge)
        }
    }

    // MARK: Export

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GroupLabel("Back up")
            VStack(alignment: .leading, spacing: Space.l) {
                Picker("", selection: $everything) {
                    Text("Everything").tag(true)
                    Text("Choose what to include").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .font(TextStyle.body)

                if !everything { chooser }

                HStack(spacing: Space.s) {
                    summary
                    Spacer()
                    Button(action: export) { Label("Export backup…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.primary)
                        .disabled(isEmpty)
                }
                if let saved {
                    Notice(symbol: "checkmark.circle.fill", text: "Saved \(saved.lastPathComponent).", tone: .ok) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }.buttonStyle(.secondary)
                    }
                }
                if let error { Notice(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger) }
                Text("Keep it anywhere: iCloud Drive, a USB stick, your password manager. Without the Recovery Key it's unreadable. Wrangler logins, `~/.aws` and shell hooks live outside the vault and aren't included.")
                    .font(TextStyle.small).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.l)
            .card()
        }
    }

    private var summary: some View {
        let subset = vault.data.subset(selection)
        let keys = subset.items.filter { $0.kind == .apiKey || $0.kind == .note }.count
        let codes = subset.items.filter { $0.kind == .backupCodes }.count
        return HStack(spacing: Space.xs) {
            Pill(text: "\(subset.projects.count) project\(subset.projects.count == 1 ? "" : "s")", symbol: "folder")
            Pill(text: "\(keys) key\(keys == 1 ? "" : "s")", symbol: "key.fill")
            Pill(text: "\(codes) code set\(codes == 1 ? "" : "s")", symbol: "list.number")
            Pill(text: "\(subset.identities.count) account\(subset.identities.count == 1 ? "" : "s")", symbol: "person.2.fill")
        }
    }

    private var chooser: some View {
        let keys = vault.data.items.filter { ($0.kind == .apiKey || $0.kind == .note) && !$0.tags.contains("identity") }
        let codes = vault.data.items.filter { $0.kind == .backupCodes }
        return VStack(alignment: .leading, spacing: Space.l) {
            checklist("Projects", vault.data.projects.map { project in (project.id, project.name, "\(vault.data.items.filter { $0.projectID == project.id }.count) variables") }, $projectIDs)
            checklist("Keys", keys.map { ($0.id, $0.name, Brand.of($0).name) }, $itemIDs)
            checklist("Backup codes", codes.map { item in (item.id, item.name, "\(item.codes.filter { $0.usedAt == nil }.count) left") }, $itemIDs)
            checklist("Accounts", vault.data.identities.map { ($0.id, $0.name, $0.provider.displayName) }, $identityIDs)
            Toggle("Activity log", isOn: $includeActivity).toggleStyle(.checkbox).font(TextStyle.body)
            Text("A project brings its variables and the shared keys they link to. An account brings its token.")
                .font(TextStyle.small).foregroundStyle(Palette.ink2)
        }
        .padding(Space.m)
        .sunken(radius: Radius.control)
    }

    private func checklist(_ title: String, _ rows: [(UUID, String, String)], _ ids: Binding<Set<UUID>>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title).font(TextStyle.smallStrong).foregroundStyle(Palette.ink2)
                Spacer()
                if !rows.isEmpty {
                    let all = rows.allSatisfy { ids.wrappedValue.contains($0.0) }
                    Button(all ? "None" : "All") {
                        if all { ids.wrappedValue.subtract(rows.map(\.0)) } else { ids.wrappedValue.formUnion(rows.map(\.0)) }
                    }
                    .buttonStyle(.quiet)
                }
            }
            if rows.isEmpty {
                Text("None in this vault").font(TextStyle.small).foregroundStyle(Palette.ink3)
            }
            ForEach(rows, id: \.0) { id, name, detail in
                Toggle(isOn: Binding(get: { ids.wrappedValue.contains(id) },
                                     set: { if $0 { ids.wrappedValue.insert(id) } else { ids.wrappedValue.remove(id) } })) {
                    HStack(spacing: Space.s) {
                        Text(name).font(TextStyle.body)
                        Text(detail).font(TextStyle.small).foregroundStyle(Palette.ink2)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func export() {
        error = nil
        saved = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.redactBackup]
        panel.canCreateDirectories = true
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = everything ? "Redact backup \(day).redact" : "Redact partial backup \(day).redact"
        panel.message = "The file is encrypted. Your Recovery Key opens it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try vault.makeBackup(selection).write(to: url)
            saved = url
        } catch {
            self.error = "Couldn't save the backup: \(error.localizedDescription)"
        }
    }

    // MARK: Restore

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GroupLabel("Restore")
            HStack(spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Bring items back from a backup").font(TextStyle.bodyStrong).foregroundStyle(Palette.ink)
                    Text("You see what's new or changed and pick what to restore. Nothing else in this vault is touched.")
                        .font(TextStyle.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { restoreURL = chooseBackup() } label: { Label("Restore from backup…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.secondary)
            }
            .padding(Space.l)
            .card()
        }
    }

    // MARK: Recovery Key

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GroupLabel("Recovery Key")
            HStack(spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Lost your Recovery Key?").font(TextStyle.bodyStrong).foregroundStyle(Palette.ink)
                    Text("Make a new one while Touch ID still works. The old key stops working, and so do backups made with it, so export a new backup afterwards.")
                        .font(TextStyle.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { confirmReplaceRecoveryKey() } label: { Label("Replace Recovery Key…", systemImage: "key") }
                    .buttonStyle(.secondary)
            }
            .padding(Space.l)
            .card()
        }
        .sheet(item: Binding(get: { newRecoveryKey.map(RevealedKey.init) }, set: { newRecoveryKey = $0?.text })) { revealed in
            RecoveryKeySheet(key: revealed.text)
        }
    }

    private func confirmReplaceRecoveryKey() {
        let alert = NSAlert()
        alert.messageText = "Replace your Recovery Key?"
        alert.informativeText = "You get a new key to save. The old key stops opening this vault, and backups made before now can only be opened with the old key."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { newRecoveryKey = try await vault.replaceRecoveryKey() } catch {
                self.error = "The Recovery Key wasn't changed: \(error.localizedDescription)"
            }
        }
    }

    private var movingCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GroupLabel("Moving to a new Mac")
            VStack(alignment: .leading, spacing: Space.m) {
                step(1, "Export everything here and copy the file to the new Mac.")
                step(2, "On the new Mac, install Redact and choose **Restore from backup** on the first screen (or double-click the file).")
                step(3, "Enter your Recovery Key, then set up Touch ID. Folders under another user name are moved for you.")
                step(4, "Follow the short checklist for what lives outside the vault: Wrangler logins, AWS profiles, shell and agent setup.")
            }
            .padding(Space.l)
            .card()
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text("\(number)")
                .font(TextStyle.captionStrong).monospacedDigit()
                .foregroundStyle(Palette.accentInk)
                .frame(width: 20, height: 20)
                .background(Palette.accent, in: Circle())
            Text(LocalizedStringKey(text)).font(TextStyle.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

func chooseBackup() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.redactBackup]
    panel.allowsMultipleSelection = false
    panel.prompt = "Restore"
    panel.message = "Choose a Redact backup (.redact)."
    return panel.runModal() == .OK ? panel.url : nil
}

// MARK: - Restore sheet

struct RestoreSheet: View {
    enum Mode { case merge, newVault }

    @EnvironmentObject var vault: VaultController
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let mode: Mode

    @State private var file: VaultFile?
    @State private var recoveryText = ""
    @State private var error: String?
    @State private var opened: (data: VaultData, key: SymmetricKey)?
    @State private var plan: RestorePlan?
    @State private var remap: PathRemap?
    @State private var useRemap = true
    @State private var finished: VaultData?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if let finished {
                RestoreChecklist(restored: finished) { dismiss() }
            } else if opened == nil {
                unlockStep
            } else {
                reviewStep
            }
        }
        .padding(Space.xl)
        .frame(width: 640)
        .canvas()
        .onAppear(perform: load)
    }

    // MARK: Step 1: Recovery Key

    private var unlockStep: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.m) {
                RedactMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .newVault ? "Restore your vault" : "Restore from backup").font(TextStyle.title).foregroundStyle(Palette.ink)
                    Text(url.lastPathComponent).font(TextStyle.mono).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.middle)
                }
            }
            if let info = file?.backup {
                HStack(spacing: Space.xs) {
                    Pill(text: info.partial ? "Partial backup" : "Full backup", symbol: info.partial ? "square.on.square.dashed" : "checkmark.seal.fill",
                         tone: info.partial ? .neutral : .ok)
                    Pill(text: "\(info.projects) projects", symbol: "folder")
                    Pill(text: "\(info.keys) keys", symbol: "key.fill")
                    Pill(text: "\(info.codeSets) code sets", symbol: "list.number")
                    Pill(text: "\(info.accounts) accounts", symbol: "person.2.fill")
                }
                Text("Made \(info.createdAt.formatted(date: .abbreviated, time: .shortened))").font(TextStyle.small).foregroundStyle(Palette.ink2)
            } else if file != nil {
                Notice(symbol: "info.circle.fill", text: "This is a vault file, not an exported backup. It restores the same way.", tone: .neutral)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                GroupLabel("Recovery Key of the vault this backup came from")
                Field(placeholder: "XXXX-XXXX-XXXX-…", text: $recoveryText, secure: true, mono: true)
                    .onSubmit(unlock)
            }
            if let error { Notice(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button("Open backup", action: unlock)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(file == nil || recoveryText.isEmpty)
            }
        }
    }

    // MARK: Step 2: review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(mode == .newVault ? "Ready to restore" : "Choose what to restore").font(TextStyle.title).foregroundStyle(Palette.ink)
                Text(mode == .newVault
                     ? "Everything in the backup becomes this Mac's vault. Touch ID is set up for this Mac; your Recovery Key keeps working."
                     : "Restored items replace their copies in this vault. Items you don't check, and everything not in the backup, stay as they are.")
                    .font(TextStyle.body).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }

            if let remap {
                VStack(alignment: .leading, spacing: Space.s) {
                    Toggle(isOn: $useRemap) {
                        (Text("Move folders from ") + Text(remap.from).font(TextStyle.mono) + Text(" to ") + Text(remap.to).font(TextStyle.mono))
                            .font(TextStyle.body)
                    }
                    .toggleStyle(.checkbox)
                    Text("The backup was made under another user name. Projects and account bindings point at the new home folder.")
                        .font(TextStyle.small).foregroundStyle(Palette.ink2)
                }
                .padding(Space.m)
                .sunken(radius: Radius.card)
            }

            let missing = PathRemap.missing(in: PathRemap.paths(in: selectedData), remap: useRemap ? remap : nil)
            if !missing.isEmpty {
                Notice(symbol: "folder.badge.questionmark",
                       text: "\(missing.count) folder\(missing.count == 1 ? " doesn't" : "s don't") exist on this Mac yet. Their variables are restored anyway and apply once you clone the repo to the same place.")
            }

            if mode == .merge, plan != nil { planList }
            else if let opened { newVaultSummary(opened.data) }

            if let error { Notice(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button(mode == .newVault ? "Restore and set up Touch ID" : "Restore \(plan?.rows.filter(\.selected).count ?? 0) items", action: restore)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .merge && (plan?.rows.contains(where: \.selected) != true))
            }
        }
    }

    /// What will actually be written (for the missing-folder check).
    private var selectedData: VaultData {
        guard let opened else { return VaultData() }
        guard mode == .merge, let plan else { return opened.data }
        let ids = Set(plan.rows.filter(\.selected).map(\.id))
        var data = opened.data
        data.projects.removeAll { !ids.contains($0.id) }
        data.identities.removeAll { !ids.contains($0.id) }
        return data
    }

    private var planList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array((plan?.rows ?? []).enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rule(inset: 40) }
                    HStack(spacing: Space.m) {
                        Toggle("", isOn: Binding(get: { plan?.rows[index].selected ?? false }, set: { plan?.rows[index].selected = $0 }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Image(systemName: symbol(row.kind)).font(.system(size: 12)).foregroundStyle(Palette.ink3).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(row.kind == .project ? TextStyle.bodyStrong : TextStyle.body).foregroundStyle(Palette.ink)
                            Text(row.detail).font(TextStyle.small).foregroundStyle(Palette.ink2)
                        }
                        Spacer()
                        switch row.status {
                        case .new: Pill(text: "New", symbol: "plus", tone: .ok)
                        case .changed: Pill(text: "Differs here", symbol: "arrow.triangle.2.circlepath", tone: .warning)
                        case .same: Pill(text: "Same", symbol: "equal")
                        }
                    }
                    .padding(.horizontal, Space.m)
                    .frame(minHeight: 44)
                }
            }
        }
        // A ScrollView in a sheet shrinks to almost nothing unless it has a minimum height.
        .frame(minHeight: min(CGFloat(plan?.rows.count ?? 0) * 46, 320), maxHeight: 420)
        .card()
    }

    private func newVaultSummary(_ data: VaultData) -> some View {
        let keys = data.items.filter { $0.kind == .apiKey || $0.kind == .note }.count
        let codes = data.items.filter { $0.kind == .backupCodes }.count
        let variables = data.items.filter { $0.kind == .variable }.count
        return HStack(spacing: Space.xs) {
            Pill(text: "\(data.projects.count) projects", symbol: "folder")
            Pill(text: "\(variables) variables", symbol: "list.bullet.rectangle")
            Pill(text: "\(keys) keys", symbol: "key.fill")
            Pill(text: "\(codes) code sets", symbol: "list.number")
            Pill(text: "\(data.identities.count) accounts", symbol: "person.2.fill")
        }
    }

    private func symbol(_ kind: RestorePlan.Kind) -> String {
        switch kind {
        case .project: "folder"
        case .key: "key"
        case .codes: "list.number"
        case .note: "note.text"
        case .account: "person.2"
        }
    }

    // MARK: Actions

    private func load() {
        do { file = try VaultFile.load(from: url) } catch { self.error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    private func unlock() {
        guard let file else { return }
        do {
            let result = try VaultController.openBackup(file, recoveryKey: recoveryText)
            recoveryText = ""
            error = nil
            remap = PathRemap.suggest(for: PathRemap.paths(in: result.data))
            if mode == .merge { plan = RestorePlan(backup: result.data, current: vault.data) }
            opened = result
        } catch {
            self.error = "That Recovery Key doesn't open this backup. Use the key of the vault the backup came from."
        }
    }

    private func restore() {
        guard let opened, let file else { return }
        let mapping = useRemap ? remap : nil
        let apply: (String) -> String = { mapping?.apply($0) ?? $0 }
        do {
            switch mode {
            case .newVault:
                var data = opened.data
                for i in data.projects.indices { data.projects[i].path = apply(data.projects[i].path) }
                for i in data.identities.indices { data.identities[i].boundPaths = data.identities[i].boundPaths.map(apply) }
                try vault.adoptBackup(file, data: data, key: opened.key)
                finished = data
            case .merge:
                guard let plan else { return }
                vault.update { plan.apply(to: &$0, remap: apply) }
                finished = selectedData
            }
        } catch {
            self.error = "Couldn't restore: \(error.localizedDescription)"
        }
    }
}

// MARK: - After restoring

/// What lives outside the vault and needs a minute on the new Mac.
struct RestoreChecklist: View {
    let restored: VaultData
    let done: () -> Void

    var body: some View {
        let aws = restored.identities.compactMap { identity -> String? in
            if case let .awsProfile(name) = identity.mode { return name } else { return nil }
        }
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Restored", systemImage: "checkmark.circle.fill")
                .labelStyle(TightLabelStyle())
                .font(TextStyle.title)
                .foregroundStyle(Palette.ok)
            Text("Your secrets are back. A few things live outside the vault, so set them up once on this Mac:")
                .font(TextStyle.body).foregroundStyle(Palette.ink2)
            VStack(spacing: 0) {
                item("Cloudflare logins", "Wrangler keeps its own logins. Recreate each profile, then bind folders in Accounts.",
                     command: "wrangler auth create <profile>")
                Rule(inset: Space.m)
                if !aws.isEmpty {
                    item("AWS profiles", "These accounts use profiles from ~/.aws/config: \(aws.joined(separator: ", ")). Copy that file or run aws configure.",
                         command: "aws configure --profile \(aws[0])")
                    Rule(inset: Space.m)
                }
                item("Shell", "Lets plain wrangler, gh and vercel pick the right account per folder.",
                     command: #"eval "$(redact hook zsh)""#)
                Rule(inset: Space.m)
                item("Pre-commit check", "Run in each repo to block commits that contain secrets.", command: "redact hook install")
                Rule(inset: Space.m)
                item("Claude Code", "Gives agents the MCP tools again.", command: "claude mcp add redact -- ~/.local/bin/redact mcp")
            }
            .card()
            HStack {
                Spacer()
                Button("Done", action: done).buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func item(_ title: String, _ detail: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(TextStyle.bodyStrong).foregroundStyle(Palette.ink)
            Text(detail).font(TextStyle.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.xs) {
                Text(command).font(TextStyle.monoSmall).foregroundStyle(Palette.ink).textSelection(.enabled)
                    .padding(.horizontal, Space.s).frame(height: 24).sunken(radius: Radius.chip)
                IconButton(symbol: "doc.on.doc", help: "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RevealedKey: Identifiable {
    let text: String
    var id: String { text }
}

/// Shows a new Recovery Key once, with copy and print, until the user says it's saved.
struct RecoveryKeySheet: View {
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.m) {
                RedactMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your new Recovery Key").font(TextStyle.title).foregroundStyle(Palette.ink)
                    Text("Shown once. Keep it in your password manager or print it.").font(TextStyle.small).foregroundStyle(Palette.ink2)
                }
            }
            Text(key)
                .font(TextStyle.monoLarge)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(Space.l)
                .sunken(radius: Radius.card)
            HStack(spacing: Space.s) {
                Button { Clipboard.copy(key) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { printRecoveryKey(key) } label: { Label("Print…", systemImage: "printer") }
            }
            .buttonStyle(.secondary)
            Notice(symbol: "info.circle.fill", text: "Next: export a new backup. Older backups only open with the old key.", tone: .neutral)
            HStack {
                Toggle("I've saved my new Recovery Key", isOn: $saved).toggleStyle(.checkbox)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(!saved)
            }
        }
        .padding(Space.xl)
        .frame(width: 560)
        .canvas()
        .interactiveDismissDisabled()
    }
}

func printRecoveryKey(_ key: String) {
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
    text.string = "Redact Recovery Key\n\n\(key)\n\nCreated \(Date().formatted(date: .long, time: .shortened)). Keep this somewhere safe."
    text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    NSPrintOperation(view: text).run()
}
