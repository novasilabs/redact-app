import RedactCore
import SwiftUI

/// Standalone keys (`.apiKey`) or backup code sets (`.backupCodes`): a list and an inspector.
struct KeysView: View {
    @EnvironmentObject var vault: VaultController
    let kind: Item.Kind
    @State private var search = ""
    @State private var selection: UUID?
    @State private var showAdd = false

    var items: [Item] {
        vault.data.items
            .filter { $0.kind == kind }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: Space.s) {
                    Text(kind == .backupCodes ? "Backup codes" : "Keys").font(TextStyle.heading).foregroundStyle(Palette.ink)
                    Text("\(vault.data.items.filter { $0.kind == kind }.count)")
                        .font(TextStyle.small).monospacedDigit().foregroundStyle(Palette.ink2)
                    Spacer()
                    Button { showAdd = true } label: { Label(kind == .backupCodes ? "Add codes" : "Add key", systemImage: "plus") }
                        .buttonStyle(.primary)
                        .help(kind == .backupCodes ? "Paste a set of recovery codes (⌘N)" : "Paste a key (⌘N)")
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.xl)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    TextField("Search", text: $search).textFieldStyle(.plain).font(TextStyle.body)
                }
                .padding(.horizontal, Space.s)
                .frame(height: 28)
                .sunken()
                .padding(Space.m)

                List(items, selection: $selection) { item in
                    KeyListRow(item: item).tag(item.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if items.isEmpty {
                        Text(search.isEmpty ? "Nothing here yet" : "No matches")
                            .font(TextStyle.body).foregroundStyle(Palette.ink2)
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
            .background(Palette.canvas)
            .onReceive(NotificationCenter.default.publisher(for: .redactDevSelectFirst)) { _ in selection = items.first?.id }

            Group {
                if let id = selection, let item = vault.data.items.first(where: { $0.id == id }) {
                    if kind == .backupCodes { CodesDetail(item: item) } else { KeyDetail(item: item, onDelete: { selection = nil }) }
                } else {
                    EmptyState(symbol: kind == .backupCodes ? "list.number" : "key",
                               title: items.isEmpty ? (kind == .backupCodes ? "No backup codes yet" : "No keys yet") : "Select an item",
                               message: kind == .backupCodes
                                   ? "Paste a site's recovery codes with ⌘N. Copying one marks it used, so you always know how many are left."
                                   : "Keys are shared secrets that several projects can link to. Rotate one here and every project gets the new value.")
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
        }
        .sheet(isPresented: $showAdd) { PasteSheet(kind: kind) }
    }
}

private struct KeyListRow: View {
    @EnvironmentObject var vault: VaultController
    let item: Item

    var body: some View {
        let brand = Brand.of(item)
        HStack(spacing: Space.m) {
            BrandTile(brand: brand, size: 30, symbol: item.kind == .backupCodes ? "list.number" : "key.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(TextStyle.bodyStrong).lineLimit(1)
                Text(subtitle(brand)).font(TextStyle.small).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            trailing
        }
        .padding(.vertical, Space.xs)
    }

    private func subtitle(_ brand: Brand) -> String {
        if item.kind == .backupCodes { return "Recovery codes" }
        if item.tags.contains("identity") { return "\(brand.name) account token" }
        return brand == .generic ? "Key" : "\(brand.name) key"
    }

    @ViewBuilder private var trailing: some View {
        if item.kind == .backupCodes {
            let left = item.codes.filter { $0.usedAt == nil }.count
            Pill(text: "\(left) left", tone: left <= 2 ? .warning : .neutral)
        } else {
            let uses = vault.data.usages(of: item).count
                + vault.data.identities.filter { $0.tokenItemID == item.id }.count
            if uses == 0 { Pill(text: "Unused") } else { Pill(text: "\(uses)", symbol: "link").help("Linked in \(uses) place\(uses == 1 ? "" : "s")") }
        }
    }
}

// MARK: - Key inspector

struct KeyDetail: View {
    @EnvironmentObject var vault: VaultController
    let item: Item
    let onDelete: () -> Void
    @State private var replacing = false
    @State private var newValue = ""

    var body: some View {
        let brand = Brand.of(item)
        let usages = vault.data.usages(of: item)
        let identities = vault.data.identities.filter { $0.tokenItemID == item.id }

        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(spacing: Space.m) {
                    BrandTile(brand: brand, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(TextStyle.title).foregroundStyle(Palette.ink).textSelection(.enabled)
                        Text(brand == .generic ? "Key" : "\(brand.name) key").font(TextStyle.body).foregroundStyle(Palette.ink2)
                    }
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    GroupLabel("Value")
                    SecretValue(value: item.value)
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    GroupLabel("Details")
                    VStack(spacing: 0) {
                        InfoRow(label: "Created") { Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                        Rule(inset: Space.m)
                        InfoRow(label: "Last rotated") {
                            if let rotated = item.rotatedAt { Text(Ago.text(rotated)) } else { Text("Never").foregroundStyle(Palette.ink2) }
                        }
                        Rule(inset: Space.m)
                        InfoRow(label: "Used in") {
                            if usages.isEmpty && identities.isEmpty {
                                Text("Nowhere yet. Link it from a project's variable menu.").foregroundStyle(Palette.ink2)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(identities) { identity in
                                        HStack(spacing: Space.s) {
                                            AccountChip(brand: .of(identity.provider), name: identity.name,
                                                        help: "\(identity.provider.displayName) account")
                                            Text("\(identity.boundPaths.count) folder\(identity.boundPaths.count == 1 ? "" : "s")")
                                                .font(TextStyle.small).foregroundStyle(Palette.ink2)
                                        }
                                    }
                                    ForEach(usages) { usage in
                                        HStack(spacing: Space.s) {
                                            Text(vault.data.projects.first { $0.id == usage.projectID }?.name ?? "?").font(TextStyle.bodyStrong)
                                            Pill(text: usage.environment ?? "")
                                            Text(usage.name).font(TextStyle.mono).foregroundStyle(Palette.ink2)
                                        }
                                    }
                                }
                            }
                        }
                        if !item.notes.isEmpty {
                            Rule(inset: Space.m)
                            InfoRow(label: "Notes") { Text(item.notes).textSelection(.enabled) }
                        }
                    }
                    .card()
                }

                if replacing {
                    VStack(alignment: .leading, spacing: Space.s) {
                        GroupLabel("New value")
                        Field(placeholder: "Paste the rotated key", text: $newValue, secure: true, mono: true)
                        Text("Every linked project gets the new value right away. Push it to your hosts afterwards (`redact push`).")
                            .font(TextStyle.small).foregroundStyle(Palette.ink2)
                        HStack {
                            Spacer()
                            Button("Cancel") { replacing = false; newValue = "" }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                            Button("Replace everywhere", action: replace)
                                .buttonStyle(.primary)
                                .disabled(newValue.isEmpty)
                        }
                    }
                } else {
                    HStack {
                        Button("Delete…", action: delete).buttonStyle(.danger)
                        Spacer()
                        Button { replacing = true } label: { Label("Replace value", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.secondary)
                    }
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onChange(of: item.id) { replacing = false; newValue = "" }
    }

    private func replace() {
        let value = newValue
        vault.update { data in
            guard let index = data.items.firstIndex(where: { $0.id == item.id }) else { return }
            data.items[index].value = value
            data.items[index].rotatedAt = Date()
            data.items[index].updatedAt = Date()
        }
        replacing = false
        newValue = ""
    }

    private func delete() {
        let links = vault.data.usages(of: item).count
        let alert = NSAlert()
        alert.messageText = "Delete \(item.name)?"
        alert.informativeText = links == 0
            ? "The key is removed from the vault."
            : "\(links) linked variable\(links == 1 ? "" : "s") keep working: each gets its own copy of the value first."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        vault.update { data in
            // Linked variables keep working: give them a copy before deleting.
            for i in data.items.indices where data.items[i].linkedItemID == item.id {
                data.items[i].value = item.value
                data.items[i].linkedItemID = nil
            }
            data.items.removeAll { $0.id == item.id }
        }
        onDelete()
    }
}

// MARK: - Backup codes inspector

struct CodesDetail: View {
    @EnvironmentObject var vault: VaultController
    let item: Item
    @State private var revealed = false

    var body: some View {
        let left = item.codes.filter { $0.usedAt == nil }.count
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(spacing: Space.m) {
                    BrandTile(brand: .of(item), size: 44, symbol: "list.number")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(TextStyle.title).foregroundStyle(Palette.ink)
                        Text("\(left) of \(item.codes.count) codes left").font(TextStyle.body).monospacedDigit()
                            .foregroundStyle(left <= 2 ? Palette.warning : Palette.ink2)
                    }
                }

                if left <= 2 {
                    Notice(symbol: "exclamationmark.triangle.fill",
                           text: left == 0 ? "No codes left. Generate a new set on the site." : "Only \(left) code\(left == 1 ? "" : "s") left. Generate a new set on the site soon.")
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    GroupLabel(title: "Codes") {
                        Toggle("Show codes", isOn: $revealed).toggleStyle(.switch).controlSize(.mini).font(TextStyle.small)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: Space.s)], spacing: Space.s) {
                        ForEach(Array(item.codes.enumerated()), id: \.offset) { index, code in
                            CodeCell(index: index, code: code, revealed: revealed) { use(index, code) }
                        }
                    }
                    Text("Copying a code marks it used.").font(TextStyle.small).foregroundStyle(Palette.ink2)
                }

                Button("Delete set…", action: delete).buttonStyle(.danger)
            }
            .padding(Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onChange(of: item.id) { revealed = false }
    }

    private func use(_ index: Int, _ code: BackupCode) {
        Clipboard.copy(code.code)
        vault.update { data in
            guard let i = data.items.firstIndex(where: { $0.id == item.id }) else { return }
            data.items[i].codes[index].usedAt = Date()
        }
    }

    private func delete() {
        let alert = NSAlert()
        alert.messageText = "Delete the \(item.name) codes?"
        alert.informativeText = "All \(item.codes.count) codes are removed from the vault."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        vault.update { $0.items.removeAll { $0.id == item.id } }
    }
}

private struct CodeCell: View {
    let index: Int
    let code: BackupCode
    let revealed: Bool
    let copy: () -> Void
    @State private var hovering = false

    var body: some View {
        let used = code.usedAt != nil
        Button(action: copy) {
            HStack(spacing: Space.s) {
                Text("\(index + 1)").font(TextStyle.caption).monospacedDigit().foregroundStyle(Palette.ink3).frame(width: 16, alignment: .trailing)
                Text(revealed || used ? code.code : String(repeating: "•", count: min(code.code.count, 10)))
                    .font(TextStyle.mono)
                    .strikethrough(used)
                    .foregroundStyle(used ? Palette.ink3 : Palette.ink)
                Spacer(minLength: 0)
                if used {
                    Text("used").font(TextStyle.caption).foregroundStyle(Palette.ink2)
                } else if hovering {
                    Image(systemName: "doc.on.doc").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.ink2)
                }
            }
            .padding(.horizontal, Space.s)
            .frame(height: 32)
            .background(hovering && !used ? Palette.selected : Palette.sunken, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
            .opacity(used ? 0.7 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(used)
        .help(used ? "Used \(code.usedAt.map(Ago.text) ?? "")" : "Copy and mark used")
        .onHover { hovering = $0 }
    }
}

// MARK: - Paste anything (⌘N)

struct PasteSheet: View {
    @EnvironmentObject var vault: VaultController
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var name = ""
    @State private var kind: Item.Kind
    @State private var projectID: UUID?
    @State private var environment: String

    init(kind: Item.Kind = .apiKey, projectID: UUID? = nil, environment: String = "development") {
        _kind = State(initialValue: kind)
        _projectID = State(initialValue: projectID)
        _environment = State(initialValue: environment)
    }
    @State private var guess: SecretDetector.Guess?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Add a secret").font(TextStyle.title).foregroundStyle(Palette.ink)
                Text("Paste a key, a NAME=value line, or a set of backup codes. Redact recognizes common formats.")
                    .font(TextStyle.body).foregroundStyle(Palette.ink2)
            }
            if kind != .backupCodes {
                Field(placeholder: "Paste here", text: $value, secure: true, mono: true)
                    .onChange(of: value) { detect() }
            } else {
                TextEditor(text: $value)
                    .font(TextStyle.mono)
                    .scrollContentBackground(.hidden)
                    .padding(Space.xs)
                    .frame(height: 120)
                    .sunken()
                Text("One code per line").font(TextStyle.small).foregroundStyle(Palette.ink2)
            }
            if let guess {
                HStack(spacing: Space.s) {
                    BrandTile(brand: .named(guess.provider), size: 20, symbol: guess.kind == .backupCodes ? "list.number" : "key.fill")
                    Text("Looks like a \(guess.provider) \(guess.kind == .backupCodes ? "set" : "key")").font(TextStyle.smallStrong).foregroundStyle(Palette.ink)
                }
            }
            Picker("Type", selection: $kind) {
                Text("Key").tag(Item.Kind.apiKey)
                Text("Project variable").tag(Item.Kind.variable)
                Text("Backup codes").tag(Item.Kind.backupCodes)
                Text("Note").tag(Item.Kind.note)
            }
            .pickerStyle(.segmented)
            Field(placeholder: "Name", text: $name, mono: kind == .variable)
            if kind == .variable {
                HStack {
                    Picker("Project", selection: $projectID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(vault.data.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("Environment", selection: $environment) {
                        ForEach(vault.data.projects.first { $0.id == projectID }?.environments ?? Project.defaultEnvironments, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty || name.isEmpty || (kind == .variable && projectID == nil))
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .canvas()
        .onAppear {
            // Pre-fill from the clipboard when it looks like a secret.
            if let clip = NSPasteboard.general.string(forType: .string), SecretDetector.guess(clip) != nil, clip.count < 4000 {
                value = clip
                detect()
            }
        }
    }

    private func detect() {
        guard let detected = SecretDetector.guess(value) else { guess = nil; return }
        guess = detected
        if name.isEmpty { name = detected.suggestedName }
        if detected.kind == .backupCodes { kind = .backupCodes }
        // "NAME=value": keep only the value.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = trimmed.firstIndex(of: "="), EnvFile.isValidName(String(trimmed[..<eq])), !trimmed.contains("\n") {
            value = String(trimmed[trimmed.index(after: eq)...])
        }
    }

    private func save() {
        var item = Item(kind: kind, name: name.trimmingCharacters(in: .whitespaces), value: value.trimmingCharacters(in: .whitespacesAndNewlines))
        if kind == .backupCodes {
            item.codes = value.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { BackupCode(code: $0) }
            item.value = ""
        }
        if kind == .variable {
            item.projectID = projectID
            item.environment = environment
        }
        vault.update { $0.items.append(item) }
        dismiss()
    }
}
