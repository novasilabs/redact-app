import RedactCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case projects = "Projects", keys = "Keys", codes = "Codes", identities = "Identities", health = "Health", activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .projects: "folder"
        case .keys: "key"
        case .codes: "list.number"
        case .identities: "person.2.badge.key"
        case .health: "stethoscope"
        case .activity: "clock.arrow.circlepath"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .projects: "1"
        case .keys: "2"
        case .codes: "3"
        case .identities: "4"
        case .health: "5"
        case .activity: "6"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var vault: VaultController

    var body: some View {
        Group {
            switch vault.state {
            case .noVault: SetupView()
            case .locked: LockedView()
            case .unlocked: MainView()
            }
        }
        .animation(.easeOut(duration: 0.15), value: vault.state)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var vault: VaultController
    @State private var recoveryKey: String?
    @State private var confirmedSaved = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(.tint)
            if let recoveryKey {
                Text("Save your Recovery Key").font(.title2.bold())
                Text("It is the only way back in if Touch ID stops working or you move to a new Mac. Redact can't reset it. Print it or store it in your password manager.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                Text(recoveryKey)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Copy") { Clipboard.copy(recoveryKey) }
                    Button("Print…") { printRecoveryKey(recoveryKey) }
                }
                Toggle("I've saved my Recovery Key somewhere safe", isOn: $confirmedSaved)
                Button("Continue") { self.recoveryKey = nil }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!confirmedSaved)
            } else {
                Text("Welcome to Redact").font(.title.bold())
                Text("Your vault is one encrypted file on this Mac. Its key is held by the Secure Enclave and opened with Touch ID. There's no account and no server.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                Button("Create vault") {
                    do { recoveryKey = try vault.createVault() } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func printRecoveryKey(_ key: String) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        text.string = "Redact Recovery Key\n\n\(key)\n\nCreated \(Date().formatted(date: .long, time: .shortened)). Keep this somewhere safe."
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        NSPrintOperation(view: text).run()
    }
}

// MARK: - Locked

struct LockedView: View {
    @EnvironmentObject var vault: VaultController
    @State private var showRecovery = false
    @State private var recoveryText = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Redact is locked").font(.title2.bold())
            Button {
                Task { await vault.unlock() }
            } label: {
                Label("Unlock with Touch ID", systemImage: "touchid")
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            if let error = vault.lastError { Text(error).foregroundStyle(.red).font(.callout) }
            Button("Use Recovery Key…") { showRecovery.toggle() }
                .buttonStyle(.link)
            if showRecovery {
                HStack {
                    SecureField("XXXX-XXXX-…", text: $recoveryText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 420)
                    Button("Unlock") {
                        if vault.unlock(recoveryKey: recoveryText) { recoveryText = "" }
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main

struct MainView: View {
    @EnvironmentObject var vault: VaultController
    @State private var section: Section? = .projects
    @State private var showPaste = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                Button {
                    vault.lock()
                } label: {
                    Label("Lock", systemImage: "lock").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
        } detail: {
            switch section ?? .projects {
            case .projects: ProjectsView()
            case .keys: KeysView(kind: .apiKey)
            case .codes: KeysView(kind: .backupCodes)
            case .identities: IdentitiesView()
            case .health: HealthView()
            case .activity: ActivityView()
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showPaste = true } label: { Label("Add secret", systemImage: "plus") }
                    .keyboardShortcut("n")
                    .help("Paste anything secret (⌘N)")
            }
        }
        .sheet(isPresented: $showPaste) { PasteSheet() }
        .background {
            // ⌘1–⌘5 section shortcuts.
            ForEach(Section.allCases) { s in
                Button("") { section = s }.keyboardShortcut(s.shortcut).hidden()
            }
        }
        .onContinuousHover { _ in vault.touch() }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevSelect)) { note in
            section = (note.object as? String).flatMap(Section.init(rawValue:))
        }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevPaste)) { _ in showPaste.toggle() }
    }
}

// MARK: - Masked value

struct MaskedValue: View {
    let value: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            Text(revealed ? value : String(repeating: "•", count: 12))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(revealed ? .primary : .secondary)
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide" : "Reveal")
            Button { Clipboard.copy(value) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy (clears in 60 s)")
        }
    }
}
