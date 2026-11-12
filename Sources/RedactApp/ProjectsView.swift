import RedactCore
import SwiftUI
import UniformTypeIdentifiers

struct ProjectsView: View {
    @EnvironmentObject var vault: VaultController
    @State private var selection: UUID?
    @State private var importRoot: String?
    @State private var dropTargeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(vault.data.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.body.weight(.medium))
                            Text(abbreviate(project.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        .tag(project.id)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
                            Button("Re-scan env files…") { importRoot = project.path }
                            Divider()
                            Button("Remove project", role: .destructive) { remove(project) }
                        }
                    }
                }
                Divider()
                HStack {
                    Button { chooseFolder() } label: { Label("Add project folder…", systemImage: "folder.badge.plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 300)

            Group {
                if let id = selection, let project = vault.data.projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project, rescan: { importRoot = project.path })
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Drop a project folder here").font(.title3)
                        Text("Redact finds its .env and .dev.vars files, shows what's new or changed per environment, and saves only what you check.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath else { return }
                Task { @MainActor in importRoot = url.path }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevSelectFirst)) { _ in
            selection = vault.data.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevImport)) { note in importRoot = note.object as? String }
        .sheet(item: Binding(get: { importRoot.map(ImportTarget.init) }, set: { importRoot = $0?.path })) { target in
            ImportSheet(root: target.path) { projectID in selection = projectID }
        }
        .navigationTitle("Projects")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Project"
        if panel.runModal() == .OK, let url = panel.url { importRoot = url.path }
    }

    private func remove(_ project: Project) {
        let alert = NSAlert()
        alert.messageText = "Remove \(project.name)?"
        alert.informativeText = "Its \(vault.data.items.filter { $0.projectID == project.id }.count) variables will be deleted from the vault. Files on disk are not touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        vault.update { data in
            data.items.removeAll { $0.projectID == project.id }
            data.projects.removeAll { $0.id == project.id }
        }
        selection = nil
    }
}

struct ImportTarget: Identifiable {
    let path: String
    var id: String { path }
}

func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

// MARK: - Project detail

struct ProjectDetailView: View {
    @EnvironmentObject var vault: VaultController
    let project: Project
    let rescan: () -> Void
    @State private var environment = "development"
    @State private var newName = ""
    @State private var newValue = ""
    @State private var linkTarget: Item?

    var variables: [Item] { vault.data.variables(projectID: project.id, environment: environment) }

    /// The default environment, unless it is empty and another one has variables.
    var initialEnvironment: String {
        if !vault.data.variables(projectID: project.id, environment: project.defaultEnvironment).isEmpty { return project.defaultEnvironment }
        return project.environments.first { !vault.data.variables(projectID: project.id, environment: $0).isEmpty } ?? project.defaultEnvironment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.title2.bold())
                    Text(abbreviate(project.path)).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(project.path)
                }
                Spacer()
                Button("Re-scan files…", action: rescan)
            }
            .padding([.horizontal, .top], 16)

            Picker("Environment", selection: $environment) {
                ForEach(project.environments, id: \.self) { env in
                    Text("\(env) (\(vault.data.variables(projectID: project.id, environment: env).count))").tag(env)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)

            Table(variables) {
                TableColumn("Name") { item in
                    HStack(spacing: 4) {
                        if item.linkedItemID != nil {
                            Image(systemName: "link").foregroundStyle(.tint).help("Linked to a shared key")
                        }
                        Text(item.name).font(.system(.body, design: .monospaced))
                    }
                }
                .width(min: 120, ideal: 170, max: 280)
                TableColumn("Value") { item in MaskedValue(value: vault.data.resolvedValue(of: item)) }
                    .width(min: 190, ideal: 200)
                TableColumn("Updated") { item in
                    Text(ActivityView.ago.localizedString(for: item.updatedAt, relativeTo: Date()))
                        .foregroundStyle(.secondary).font(.caption)
                }
                .width(70)
            }
            .overlay {
                if variables.isEmpty {
                    VStack(spacing: 6) {
                        Text("No variables in \(environment)").font(.headline)
                        Text("Add one below, or re-scan the project's env files.").foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu(forSelectionType: Item.ID.self) { ids in
                if let id = ids.first, let item = variables.first(where: { $0.id == id }) {
                    Button("Copy value") { Clipboard.copy(vault.data.resolvedValue(of: item)) }
                    Button("Copy `redact run` command") { Clipboard.copy("redact run --env \(environment) -- ") }
                    if item.linkedItemID == nil {
                        Button("Move to Keys and link…") { promote(item) }
                    } else {
                        Button("Unlink (keep a copy)") { unlink(item) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { vault.update { $0.items.removeAll { $0.id == id } } }
                }
            }

            HStack {
                TextField("NAME", text: $newName).font(.system(.body, design: .monospaced)).frame(width: 200)
                SecureField("value", text: $newValue)
                Button("Add") { add() }
                    .disabled(!EnvFile.isValidName(newName) || newValue.isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .textFieldStyle(.roundedBorder)
            .padding(16)

            Text("Run with: redact run --env \(environment) -- <command>")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding([.horizontal, .bottom], 16)
        }
        .onAppear { environment = initialEnvironment }
        .onChange(of: project.id) { environment = initialEnvironment }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let value = newValue
        let env = environment
        vault.update { data in
            if let index = data.items.firstIndex(where: { $0.kind == .variable && $0.projectID == project.id && $0.environment == env && $0.name == name }) {
                data.items[index].value = value
                data.items[index].linkedItemID = nil
                data.items[index].updatedAt = Date()
            } else {
                data.items.append(Item(kind: .variable, name: name, value: value, projectID: project.id, environment: env))
            }
        }
        newName = ""
        newValue = ""
    }

    /// Turns a project variable into a shared key that other projects can link to.
    private func promote(_ item: Item) {
        vault.update { data in
            let shared = Item(kind: .apiKey, name: item.name, value: item.value, notes: "From \(project.name)")
            data.items.append(shared)
            if let index = data.items.firstIndex(where: { $0.id == item.id }) {
                data.items[index].linkedItemID = shared.id
                data.items[index].value = ""
            }
            // Link every other variable that holds the same value.
            for i in data.items.indices where data.items[i].kind == .variable && data.items[i].linkedItemID == nil && data.items[i].value == item.value {
                data.items[i].linkedItemID = shared.id
                data.items[i].value = ""
            }
        }
    }

    private func unlink(_ item: Item) {
        let value = vault.data.resolvedValue(of: item)
        vault.update { data in
            if let index = data.items.firstIndex(where: { $0.id == item.id }) {
                data.items[index].value = value
                data.items[index].linkedItemID = nil
            }
        }
    }
}

// MARK: - Import sheet

struct ImportSheet: View {
    @EnvironmentObject var vault: VaultController
    @Environment(\.dismiss) private var dismiss
    let root: String
    let onDone: (UUID) -> Void
    @State private var plan: ImportPlan?
    @State private var error: String?
    @State private var linkDuplicates = true
    @State private var saved: (count: Int, before: VaultData, projectID: UUID)?
    @State private var trashed = false
    @State private var gitignoreAdded = false

    var project: Project? { vault.data.projects.first { $0.path == WranglerProfiles.realPath(root) } }

    var body: some View {
        if let saved { doneView(saved) } else { reviewView }
    }

    private var plaintextFiles: [ProjectScanner.Found] { plan?.files.filter { !$0.isExample } ?? [] }

    private var gitignoreNeedsEnv: Bool {
        let root = WranglerProfiles.realPath(self.root)
        guard FileManager.default.fileExists(atPath: root + "/.git") else { return false }
        let ignore = (try? String(contentsOfFile: root + "/.gitignore", encoding: .utf8)) ?? ""
        let lines = Set(ignore.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return lines.isDisjoint(with: [".env", ".env*", ".env.*", "*.env", ".env*.local"])
    }

    private func doneView(_ saved: (count: Int, before: VaultData, projectID: UUID)) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Saved \(saved.count) variable\(saved.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)
            Text("Your project can now run with `redact run -- <command>`. The plaintext files below are no longer needed.")
                .foregroundStyle(.secondary)
            if !plaintextFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plaintextFiles, id: \.path) { file in
                        Label(file.relativePath, systemImage: trashed ? "trash" : "doc.plaintext")
                            .font(.callout.monospaced())
                            .foregroundStyle(trashed ? .secondary : .primary)
                    }
                }
                Button(trashed ? "Moved to Trash" : "Move \(plaintextFiles.count) plaintext file\(plaintextFiles.count == 1 ? "" : "s") to Trash") { trashFiles() }
                    .disabled(trashed)
                Text("They stay recoverable in the Trash until you empty it.").font(.caption).foregroundStyle(.secondary)
            }
            if gitignoreNeedsEnv || gitignoreAdded {
                Button(gitignoreAdded ? "Added to .gitignore" : "Add .env files to .gitignore") { addGitignore() }
                    .disabled(gitignoreAdded)
            }
            HStack {
                Button("Undo import") {
                    let before = saved.before
                    vault.update { data in
                        let activity = data.activity
                        data = before
                        data.activity = activity
                    }
                    dismiss()
                }
                Spacer()
                Button("Done") { onDone(saved.projectID); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func trashFiles() {
        for file in plaintextFiles {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
        }
        trashed = true
    }

    private func addGitignore() {
        let path = WranglerProfiles.realPath(root) + "/.gitignore"
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n# Secrets live in Redact\n.env\n.env.*\n!.env.example\n.dev.vars\n.dev.vars.*\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        gitignoreAdded = true
    }

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(project == nil ? "Add \((root as NSString).lastPathComponent)" : "Re-scan \(project!.name)").font(.title2.bold())
            Text(abbreviate(root)).foregroundStyle(.secondary).font(.callout).lineLimit(1).truncationMode(.middle)

            if let error { Text(error).foregroundStyle(.red) }
            if let plan {
                if plan.rows.isEmpty {
                    Text("No .env or .dev.vars files found. The project will be created empty; add variables by hand or with `redact set`.")
                        .foregroundStyle(.secondary)
                } else {
                    summary(plan)
                    Table(plan.rows) {
                        TableColumn("") { row in
                            Toggle("", isOn: binding(for: row)).labelsHidden().disabled(row.shadowed)
                        }
                        .width(24)
                        TableColumn("Variable") { row in
                            Text(row.name).font(.system(.body, design: .monospaced))
                                .strikethrough(row.shadowed)
                                .foregroundStyle(row.shadowed ? .secondary : .primary)
                        }
                        TableColumn("Env") { row in Text(row.environment) }.width(90)
                        TableColumn("Status") { row in statusBadge(row) }.width(150)
                        TableColumn("File") { row in Text(row.sourceFile).foregroundStyle(.secondary).font(.caption) }
                    }
                    .frame(minHeight: 260)
                    if !plan.missingFromExample.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Listed in .env.example but missing", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            ForEach(plan.missingFromExample.sorted { $0.key < $1.key }, id: \.key) { env, names in
                                Text("\(env): \(names.joined(separator: ", "))").font(.caption.monospaced())
                            }
                        }
                    }
                    Toggle("Link values that match an existing key (rotate once, update everywhere)", isOn: $linkDuplicates)
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(project == nil ? "Add project" : "Save selected") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
            }
        }
        .padding(20)
        .frame(width: 760)
        .task { load() }
    }

    private func summary(_ plan: ImportPlan) -> some View {
        let counts = Dictionary(grouping: plan.rows.filter { !$0.shadowed }, by: \.status).mapValues(\.count)
        return HStack(spacing: 14) {
            Text("\(plan.files.filter { !$0.isExample }.count) files")
            Text("\(counts[.new] ?? 0) new").foregroundStyle(.green)
            Text("\(counts[.changed] ?? 0) changed").foregroundStyle(.orange)
            Text("\(counts[.unchanged] ?? 0) unchanged").foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder private func statusBadge(_ row: ImportPlan.Row) -> some View {
        if row.shadowed {
            Text("overridden").foregroundStyle(.secondary)
        } else if let name = row.duplicateName, linkDuplicates {
            Label("links to \(name)", systemImage: "link").foregroundStyle(.tint).lineLimit(1)
        } else {
            switch row.status {
            case .new: Text("new").foregroundStyle(.green)
            case .changed: Text("changed").foregroundStyle(.orange)
            case .unchanged: Text("unchanged").foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for row: ImportPlan.Row) -> Binding<Bool> {
        Binding(
            get: { plan?.rows.first { $0.id == row.id }?.selected ?? false },
            set: { newValue in
                guard let index = plan?.rows.firstIndex(where: { $0.id == row.id }) else { return }
                plan?.rows[index].selected = newValue
            }
        )
    }

    private func load() {
        do { plan = try ImportPlan.build(root: root, project: project, vault: vault.data) } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let plan else { return }
        let path = WranglerProfiles.realPath(root)
        let before = vault.data
        var projectID = project?.id
        vault.update { data in
            var target = data.projects.first { $0.path == path }
            if target == nil {
                let created = Project(name: (path as NSString).lastPathComponent, path: path)
                data.projects.append(created)
                target = created
            }
            guard var target else { return }
            for env in Set(plan.rows.map(\.environment)) where !target.environments.contains(env) {
                target.environments.append(env)
            }
            if let index = data.projects.firstIndex(where: { $0.id == target.id }) { data.projects[index] = target }
            plan.apply(to: &data, project: target, linkDuplicates: linkDuplicates)
            projectID = target.id
        }
        guard let projectID else { dismiss(); return }
        let count = plan.rows.filter { $0.selected && !$0.shadowed }.count
        if plaintextFiles.isEmpty && !gitignoreNeedsEnv {
            onDone(projectID)
            dismiss()
        } else {
            saved = (count, before, projectID)
        }
    }
}
