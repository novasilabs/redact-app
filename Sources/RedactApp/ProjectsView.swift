import RedactCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportTarget: Identifiable {
    let path: String
    var id: String { path }
}

func abbreviate(_ path: String) -> String {
    if let alias = DevSnapshot.pathAlias, path.hasPrefix(alias.from) {
        return alias.to + path.dropFirst(alias.from.count)
    }
    return (path as NSString).abbreviatingWithTildeInPath
}

// MARK: - All projects

struct ProjectsOverview: View {
    @EnvironmentObject var vault: VaultController
    let open: (UUID) -> Void
    let add: () -> Void
    let importFolder: (String) -> Void
    @State private var dropTargeted = false

    private var projects: [Project] {
        vault.data.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                PageHeader(title: "Projects",
                           subtitle: "Each project is a folder. `redact run` gives its commands the variables for one environment, and they never touch the disk.") {
                    Button(action: add) { Label("Add folder", systemImage: "plus") }.buttonStyle(.primary)
                }

                if projects.isEmpty {
                    dropZone(large: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 { Rule(inset: 56) }
                            ProjectRow(project: project) { open(project.id) }
                        }
                    }
                    .card()
                    dropZone(large: false)
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath else { return }
                Task { @MainActor in importFolder(url.path) }
            }
            return true
        }
    }

    private func dropZone(large: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return Group {
            if large {
                EmptyState(symbol: "tray.and.arrow.down", title: "Drop a project folder here",
                           message: "Redact finds its .env and .dev.vars files, shows what's new per environment, and saves only what you check.") {
                    Button("Choose folder…", action: add).buttonStyle(.secondary)
                }
                .padding(.vertical, Space.xxl)
            } else {
                Label("Drop another folder here to import its env files", systemImage: "tray.and.arrow.down")
                    .labelStyle(TightLabelStyle())
                    .font(TextStyle.small)
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity)
                    .padding(Space.l)
            }
        }
        .background(dropTargeted ? Palette.accentSoft : .clear, in: shape)
        .overlay(shape.strokeBorder(dropTargeted ? Palette.accentText : Palette.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct ProjectRow: View {
    @EnvironmentObject var vault: VaultController
    let project: Project
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.m) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 32, height: 32)
                    .sunken(radius: Radius.tile)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(TextStyle.bodyStrong).foregroundStyle(Palette.ink)
                    PathLabel(path: project.path)
                }
                Spacer(minLength: Space.l)
                HStack(spacing: Space.xs) {
                    ForEach(project.environments, id: \.self) { env in
                        let count = vault.data.variables(projectID: project.id, environment: env).count
                        if count > 0 { Pill(text: "\(env) \(count)") }
                    }
                }
                HStack(spacing: Space.xs) {
                    ForEach(vault.data.boundIdentities(for: project.path).values.map(\.0).sorted { $0.name < $1.name }) { identity in
                        BrandTile(brand: .of(identity.provider), size: 18).help("\(identity.provider.displayName) account \(identity.name)")
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, 10)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Project detail

struct ProjectDetailView: View {
    @EnvironmentObject var vault: VaultController
    let project: Project
    let rescan: () -> Void
    @State private var environment = "development"
    @State private var adding = false
    @State private var tableWidth: CGFloat = 1000
    @State private var newName = ""
    @State private var newValue = ""
    @State private var copiedCommand = false
    @FocusState private var nameFocused: Bool

    var variables: [Item] { vault.data.variables(projectID: project.id, environment: environment) }

    /// The default environment, unless it is empty and another one has variables.
    var initialEnvironment: String {
        if !vault.data.variables(projectID: project.id, environment: project.defaultEnvironment).isEmpty { return project.defaultEnvironment }
        return project.environments.first { !vault.data.variables(projectID: project.id, environment: $0).isEmpty } ?? project.defaultEnvironment
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                EnvironmentTabs(environments: project.environments, selection: $environment) { env in
                    vault.data.variables(projectID: project.id, environment: env).count
                }
                variablesCard
            }
            .padding(Space.xl)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { runStrip }
        .onAppear { environment = initialEnvironment }
        .onChange(of: environment) { adding = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(project.name).font(TextStyle.title).foregroundStyle(Palette.ink)
                PathLabel(path: project.path, font: TextStyle.mono)
                accounts
            }
            Spacer(minLength: Space.l)
            Button(action: rescan) { Label("Re-scan files", systemImage: "arrow.clockwise") }.buttonStyle(.secondary)
            Button { startAdding() } label: { Label("Add variable", systemImage: "plus") }
                .buttonStyle(.primary)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Add a variable to \(environment) (⇧⌘N)")
        }
    }

    /// Which accounts a command run here gets (the per-folder switcher, made visible).
    @ViewBuilder private var accounts: some View {
        let bound = vault.data.boundIdentities(for: project.path).values.map(\.0).sorted { $0.provider.rawValue < $1.provider.rawValue }
        let wrangler = DevSnapshot.directory == nil
            ? WranglerProfiles(configRoot: WranglerProfiles.defaultConfigRoot()).resolve(directory: project.path, environment: [:]).profile
            : "default"
        if !bound.isEmpty || wrangler != "default" {
            HStack(spacing: Space.s) {
                Text("Runs as").font(TextStyle.small).foregroundStyle(Palette.ink2)
                if wrangler != "default" {
                    AccountChip(brand: .named("Cloudflare"), name: wrangler, help: "Wrangler profile bound to this folder")
                }
                ForEach(bound) { identity in
                    AccountChip(brand: .of(identity.provider), name: identity.name,
                                help: "\(identity.provider.displayName) account \(identity.name), set for commands run here")
                }
            }
        }
    }

    // MARK: Variables

    private var variablesCard: some View {
        VStack(spacing: 0) {
            if adding {
                newVariableRow
                if !variables.isEmpty { Rule() }
            }
            ForEach(Array(variables.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rule(inset: Space.m) }
                VariableRow(item: item, value: vault.data.resolvedValue(of: item), linkedName: linkedName(item),
                            density: RowDensity.fitting(tableWidth, hasLinks: variables.contains { linkedName($0) != nil })) {
                    menu(for: item)
                }
            }
            if variables.isEmpty && !adding {
                EmptyState(symbol: "list.bullet.rectangle", title: "No variables in \(environment)",
                           message: "Add one by hand, or re-scan the folder's env files.") {
                    Button { startAdding() } label: { Label("Add variable", systemImage: "plus") }.buttonStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { tableWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in tableWidth = width }
        })
        .card()
    }

    private var newVariableRow: some View {
        HStack(spacing: Space.s) {
            Field(placeholder: "NAME", text: $newName, mono: true)
                .frame(width: 220)
                .focused($nameFocused)
                .onChange(of: newName) {
                    let upper = newName.uppercased()
                    if upper != newName { newName = upper }
                }
            Field(placeholder: "value", text: $newValue, secure: true, mono: true)
                .onSubmit(add)
            Button("Cancel") { adding = false; newName = ""; newValue = "" }
                .buttonStyle(.quiet)
                .keyboardShortcut(.cancelAction)
            Button("Save", action: add)
                .buttonStyle(.primary)
                .disabled(!EnvFile.isValidName(newName) || newValue.isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(Space.m)
        .background(Palette.accentSoft.opacity(0.5))
    }

    private func linkedName(_ item: Item) -> String? {
        guard let id = item.linkedItemID else { return nil }
        return vault.data.items.first { $0.id == id }?.name
    }

    @ViewBuilder private func menu(for item: Item) -> some View {
        Button("Copy value") { Clipboard.copy(vault.data.resolvedValue(of: item)) }
        Button("Copy name") { Clipboard.copy(item.name) }
        if item.linkedItemID == nil {
            Button("Move to Keys and link…") { promote(item) }
        } else {
            Button("Unlink (keep a copy)") { unlink(item) }
        }
        Divider()
        Button("Delete…", role: .destructive) { delete(item) }
    }

    // MARK: Run strip

    private var runStrip: some View {
        let command = "redact run --env \(environment) -- "
        return HStack(spacing: Space.s) {
            Image(systemName: "terminal").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink3)
            (Text(command).foregroundStyle(Palette.ink) + Text("<command>").foregroundStyle(Palette.ink3))
                .font(TextStyle.mono)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Text("Output is masked").font(TextStyle.caption).foregroundStyle(Palette.ink2)
            Button {
                Clipboard.copy(command)
                copiedCommand = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedCommand = false }
            } label: {
                Label(copiedCommand ? "Copied" : "Copy", systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.quiet)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.s)
        .background(.bar)
        .overlay(alignment: .top) { Rule() }
    }

    // MARK: Actions

    private func startAdding() {
        adding = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard EnvFile.isValidName(name), !newValue.isEmpty else { return }
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
        nameFocused = true
    }

    private func delete(_ item: Item) {
        let alert = NSAlert()
        alert.messageText = "Delete \(item.name) from \(environment)?"
        alert.informativeText = item.linkedItemID == nil
            ? "The value is removed from the vault."
            : "Only this project's link is removed. The shared key stays in Keys."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        vault.update { $0.items.removeAll { $0.id == item.id } }
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

struct AccountChip: View {
    let brand: Brand
    let name: String
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            BrandTile(brand: brand, size: 16)
            Text(name).font(TextStyle.smallStrong).foregroundStyle(Palette.ink)
        }
        .padding(.leading, 3)
        .padding(.trailing, Space.s)
        .frame(height: 22)
        .background(Palette.hover, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .help(help)
    }
}

/// How much a variable row shows. Chosen once per table from its width, so columns line up and a
/// narrow window drops the timestamp (then shrinks names) instead of growing wider than the screen.
struct RowDensity: Equatable {
    var nameWidth: CGFloat
    var showsTime: Bool
    var pillText: Bool

    static let full = RowDensity(nameWidth: 220, showsTime: true, pillText: true)
    static let medium = RowDensity(nameWidth: 160, showsTime: false, pillText: true)
    static let compact = RowDensity(nameWidth: 140, showsTime: false, pillText: false)

    /// Width a row needs: name, value (min 200), reveal/copy, link pill, time, menu, gaps, padding.
    func required(hasLinks: Bool) -> CGFloat {
        let pill: CGFloat = hasLinks ? (pillText ? 190 : 22) + Space.m : 0
        let time: CGFloat = showsTime ? 76 + Space.m : 0
        return nameWidth + Space.m + 200 + 80 + pill + time + Space.m + 24 + 2 * Space.m
    }

    static func fitting(_ width: CGFloat, hasLinks: Bool) -> RowDensity {
        [full, medium].first { width >= $0.required(hasLinks: hasLinks) } ?? compact
    }
}

private struct VariableRow<MenuItems: View>: View {
    let item: Item
    let value: String
    let linkedName: String?
    var density: RowDensity = .full
    @ViewBuilder let menu: () -> MenuItems
    @State private var hovering = false

    var body: some View {
        row(nameWidth: density.nameWidth, showsTime: density.showsTime, pillText: density.pillText)
        .padding(.horizontal, Space.m)
        .frame(minHeight: 44)
        .background(hovering ? Palette.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu() }
    }

    private func row(nameWidth: CGFloat, showsTime: Bool, pillText: Bool) -> some View {
        HStack(spacing: Space.m) {
            Text(item.name)
                .font(TextStyle.monoStrong)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(width: nameWidth, alignment: .leading)
                .help(item.name)
            SecretValue(value: value)
                .layoutPriority(1)
            if let linkedName {
                Group {
                    if pillText {
                        Pill(text: linkedName, symbol: "link", tone: .accent)
                    } else {
                        Image(systemName: "link").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accentText)
                            .frame(width: 22, height: 22)
                            .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                            .accessibilityLabel("Linked to \(linkedName)")
                    }
                }
                .help("Linked to the shared key \"\(linkedName)\". Rotate it once in Keys and every project gets the new value.")
                .fixedSize()
            }
            if showsTime {
                Text(Ago.text(item.updatedAt))
                    .font(TextStyle.caption)
                    .foregroundStyle(Palette.ink2)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
                    .help("Updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            Menu { menu() } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink2)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
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
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Saved \(saved.count) variable\(saved.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .font(TextStyle.title)
                .foregroundStyle(Palette.ok)
            Text("Your project now runs with `redact run -- <command>`. The plaintext files below aren't needed any more.")
                .font(TextStyle.body)
                .foregroundStyle(Palette.ink2)
            if !plaintextFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plaintextFiles, id: \.path) { file in
                        Label(file.relativePath, systemImage: trashed ? "trash" : "doc.plaintext")
                            .labelStyle(TightLabelStyle())
                            .font(TextStyle.mono)
                            .foregroundStyle(trashed ? Palette.ink2 : Palette.ink)
                            .strikethrough(trashed)
                    }
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sunken(radius: Radius.card)
                Button(trashed ? "Moved to Trash" : "Move \(plaintextFiles.count) plaintext file\(plaintextFiles.count == 1 ? "" : "s") to Trash") { trashFiles() }
                    .buttonStyle(.secondary)
                    .disabled(trashed)
                Text("They stay recoverable in the Trash until you empty it.").font(TextStyle.caption).foregroundStyle(Palette.ink2)
            }
            if gitignoreNeedsEnv || gitignoreAdded {
                Button(gitignoreAdded ? "Added to .gitignore" : "Add .env files to .gitignore") { addGitignore() }
                    .buttonStyle(.secondary)
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
                .buttonStyle(.quiet)
                Spacer()
                Button("Done") { onDone(saved.projectID); dismiss() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .canvas()
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
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(project == nil ? "Add \((root as NSString).lastPathComponent)" : "Re-scan \(project!.name)")
                    .font(TextStyle.title).foregroundStyle(Palette.ink)
                PathLabel(path: root, font: TextStyle.mono)
            }

            if let error { Notice(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger) }
            if let plan {
                if plan.rows.isEmpty {
                    Text("No .env or .dev.vars files found. The project will be created empty; add variables by hand or with `redact set`.")
                        .font(TextStyle.body)
                        .foregroundStyle(Palette.ink2)
                } else {
                    summary(plan)
                    Table(plan.rows) {
                        TableColumn("") { row in
                            Toggle("", isOn: binding(for: row)).labelsHidden().disabled(row.shadowed)
                        }
                        .width(24)
                        TableColumn("Variable") { row in
                            Text(row.name).font(TextStyle.monoStrong)
                                .strikethrough(row.shadowed)
                                .foregroundStyle(row.shadowed ? Palette.ink2 : Palette.ink)
                        }
                        TableColumn("Env") { row in Text(row.environment).font(TextStyle.small) }.width(90)
                        TableColumn("Status") { row in statusBadge(row) }.width(150)
                        TableColumn("File") { row in Text(row.sourceFile).foregroundStyle(Palette.ink2).font(TextStyle.monoSmall) }
                    }
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
                    if !plan.missingFromExample.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Label("Listed in .env.example but missing", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(TightLabelStyle())
                                .font(TextStyle.smallStrong)
                                .foregroundStyle(Palette.warning)
                            ForEach(plan.missingFromExample.sorted { $0.key < $1.key }, id: \.key) { env, names in
                                Text("\(env): \(names.joined(separator: ", "))").font(TextStyle.monoSmall).foregroundStyle(Palette.ink2)
                            }
                        }
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.soft(Palette.warning), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    }
                    Toggle("Link values that match an existing key (rotate once, update everywhere)", isOn: $linkDuplicates)
                        .toggleStyle(.checkbox)
                        .font(TextStyle.body)
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button(project == nil ? "Add project" : "Save selected") { save() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
            }
        }
        .padding(Space.xl)
        .canvas()
        .frame(width: 760)
        .task { load() }
    }

    private func summary(_ plan: ImportPlan) -> some View {
        let counts = Dictionary(grouping: plan.rows.filter { !$0.shadowed }, by: \.status).mapValues(\.count)
        let files = plan.files.filter { !$0.isExample }.count
        return HStack(spacing: Space.s) {
            Pill(text: "\(files) file\(files == 1 ? "" : "s")", symbol: "doc")
            Pill(text: "\(counts[.new] ?? 0) new", symbol: "plus", tone: .ok)
            Pill(text: "\(counts[.changed] ?? 0) changed", symbol: "arrow.triangle.2.circlepath", tone: .warning)
            Pill(text: "\(counts[.unchanged] ?? 0) unchanged", symbol: "equal")
        }
    }

    @ViewBuilder private func statusBadge(_ row: ImportPlan.Row) -> some View {
        if row.shadowed {
            Pill(text: "overridden", symbol: "arrow.turn.down.right")
        } else if let name = row.duplicateName, linkDuplicates {
            Pill(text: name, symbol: "link", tone: .accent).help("Links to the existing key \(name)")
        } else {
            switch row.status {
            case .new: Pill(text: "new", symbol: "plus", tone: .ok)
            case .changed: Pill(text: "changed", symbol: "arrow.triangle.2.circlepath", tone: .warning)
            case .unchanged: Pill(text: "unchanged", symbol: "equal")
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
