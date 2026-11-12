import RedactCore
import SwiftUI

/// Standalone keys (`.apiKey`) or backup code sets (`.backupCodes`).
struct KeysView: View {
    @EnvironmentObject var vault: VaultController
    let kind: Item.Kind
    @State private var search = ""
    @State private var selection: UUID?

    var items: [Item] {
        vault.data.items
            .filter { $0.kind == kind }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HSplitView {
            List(items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body.weight(.medium))
                    if kind == .backupCodes {
                        let left = item.codes.filter { $0.usedAt == nil }.count
                        Text("\(left) of \(item.codes.count) left").font(.caption).foregroundStyle(left <= 2 ? .orange : .secondary)
                    } else {
                        let uses = vault.data.usages(of: item).count
                            + vault.data.identities.filter { if case let .apiToken(id, _) = $0.mode { return id == item.id } else { return false } }.count
                        Text(uses == 0 ? "not linked" : "linked in \(uses) place\(uses == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
            }
            .searchable(text: $search, placement: .sidebar)
            .onReceive(NotificationCenter.default.publisher(for: .redactDevSelectFirst)) { _ in selection = items.first?.id }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            Group {
                if let id = selection, let item = vault.data.items.first(where: { $0.id == id }) {
                    if kind == .backupCodes { CodesDetail(item: item) } else { KeyDetail(item: item) }
                } else {
                    Text(items.isEmpty ? "Nothing here yet. Press ⌘N and paste." : "Select an item")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(kind == .backupCodes ? "Codes" : "Keys")
    }
}

struct KeyDetail: View {
    @EnvironmentObject var vault: VaultController
    let item: Item
    @State private var replacing = false
    @State private var newValue = ""

    var body: some View {
        Form {
            Text(item.name).font(.title2.bold())
            LabeledContent("Value") { MaskedValue(value: item.value) }
            LabeledContent("Created") { Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)) }
            if let rotated = item.rotatedAt {
                LabeledContent("Last rotated") { Text(rotated, style: .relative) }
            }
            if !item.notes.isEmpty { LabeledContent("Notes") { Text(item.notes) } }

            let usages = vault.data.usages(of: item)
            let identities = vault.data.identities.filter { if case let .apiToken(id, _) = $0.mode { return id == item.id } else { return false } }
            LabeledContent("Used in") {
                if usages.isEmpty && identities.isEmpty {
                    Text("Nowhere yet").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading) {
                        ForEach(identities) { identity in
                            Label("\(identity.provider.displayName) account \(identity.name) (\(identity.boundPaths.count) folder\(identity.boundPaths.count == 1 ? "" : "s"))", systemImage: "person.badge.key")
                                .font(.callout)
                        }
                        ForEach(usages) { usage in
                            let project = vault.data.projects.first { $0.id == usage.projectID }?.name ?? "?"
                            Text("\(project) · \(usage.environment ?? "") · \(usage.name)").font(.callout.monospaced())
                        }
                    }
                }
            }

            if replacing {
                SecureField("New value", text: $newValue)
                HStack {
                    Button("Cancel") { replacing = false; newValue = "" }
                    Button("Replace everywhere") {
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
                    .disabled(newValue.isEmpty)
                }
                Text("Every linked project gets the new value immediately. Remember to push it to your hosts.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Replace value…") { replacing = true }
                    Button("Delete", role: .destructive) {
                        vault.update { data in
                            // Linked variables keep working: give them a copy before deleting.
                            for i in data.items.indices where data.items[i].linkedItemID == item.id {
                                data.items[i].value = item.value
                                data.items[i].linkedItemID = nil
                            }
                            data.items.removeAll { $0.id == item.id }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CodesDetail: View {
    @EnvironmentObject var vault: VaultController
    let item: Item
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.name).font(.title2.bold())
            let left = item.codes.filter { $0.usedAt == nil }.count
            if left <= 2 {
                Label("Only \(left) code\(left == 1 ? "" : "s") left. Generate new ones on the site.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("Copying a code marks it used.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show codes", isOn: $revealed).toggleStyle(.switch).controlSize(.small)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                    ForEach(Array(item.codes.enumerated()), id: \.offset) { index, code in
                        Button {
                            Clipboard.copy(code.code)
                            vault.update { data in
                                guard let i = data.items.firstIndex(where: { $0.id == item.id }) else { return }
                                data.items[i].codes[index].usedAt = Date()
                            }
                        } label: {
                            Text(revealed || code.usedAt != nil ? code.code : String(repeating: "•", count: min(code.code.count, 12)))
                                .font(.system(.body, design: .monospaced))
                                .strikethrough(code.usedAt != nil)
                                .foregroundStyle(code.usedAt != nil ? .secondary : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(8)
                                .background(.quaternary.opacity(code.usedAt != nil ? 0.3 : 1), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(code.usedAt != nil)
                    }
                }
            }
            Button("Delete set", role: .destructive) { vault.update { $0.items.removeAll { $0.id == item.id } } }
        }
        .padding(20)
        .onChange(of: item.id) { revealed = false }
    }
}

// MARK: - Paste anything (⌘N)

struct PasteSheet: View {
    @EnvironmentObject var vault: VaultController
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var name = ""
    @State private var kind: Item.Kind = .apiKey
    @State private var projectID: UUID?
    @State private var environment = "development"
    @State private var guess: SecretDetector.Guess?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a secret").font(.title2.bold())
            if kind != .backupCodes {
                SecureField("Paste a key, a NAME=value line, or backup codes", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: value) { detect() }
            } else {
                Text("One code per line").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $value).font(.system(.body, design: .monospaced)).frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            if let guess {
                Label("Looks like \(guess.provider)", systemImage: "sparkles").foregroundStyle(.tint).font(.callout)
            }
            Picker("Type", selection: $kind) {
                Text("Key").tag(Item.Kind.apiKey)
                Text("Project variable").tag(Item.Kind.variable)
                Text("Backup codes").tag(Item.Kind.backupCodes)
                Text("Note").tag(Item.Kind.note)
            }
            .pickerStyle(.segmented)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
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
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty || name.isEmpty || (kind == .variable && projectID == nil))
            }
        }
        .padding(20)
        .frame(width: 520)
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
