import RedactCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case projects = "Projects", keys = "Keys", codes = "Codes", identities = "Identities", health = "Health", activity = "Activity", backup = "Backup"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .projects: "All projects"
        case .keys: "Keys"
        case .codes: "Backup codes"
        case .identities: "Accounts"
        case .health: "Leak check"
        case .activity: "Activity"
        case .backup: "Backup & restore"
        }
    }
    var icon: String {
        switch self {
        case .projects: "square.stack.3d.up"
        case .keys: "key"
        case .codes: "list.number"
        case .identities: "person.2"
        case .health: "checkmark.shield"
        case .activity: "clock.arrow.circlepath"
        case .backup: "externaldrive"
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
        case .backup: "7"
        }
    }
}

/// What the sidebar points at: a section, or one project.
enum Destination: Hashable {
    case section(Section)
    case project(UUID)
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
        .tint(Palette.accentText)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var vault: VaultController
    @EnvironmentObject var status: AppStatus
    @State private var restoreURL: URL?
    @State private var recoveryKey: String?
    @State private var confirmedSaved = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: Space.xl) {
            RedactMark(size: 64)
            if let recoveryKey {
                VStack(spacing: Space.s) {
                    Text("Save your Recovery Key").font(TextStyle.display).foregroundStyle(Palette.ink)
                    Text("It's the only way back in if Touch ID stops working or you move to a new Mac. Redact can't reset it. Print it, or keep it in your password manager.")
                        .font(TextStyle.body).foregroundStyle(Palette.ink2)
                        .multilineTextAlignment(.center).frame(maxWidth: 440)
                }
                Text(recoveryKey)
                    .font(TextStyle.monoLarge)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
                    .padding(Space.l)
                    .sunken(radius: Radius.card)
                HStack(spacing: Space.s) {
                    Button { Clipboard.copy(recoveryKey) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { printRecoveryKey(recoveryKey) } label: { Label("Print…", systemImage: "printer") }
                }
                .buttonStyle(.secondary)
                Toggle("I've saved my Recovery Key somewhere safe", isOn: $confirmedSaved)
                    .toggleStyle(.checkbox)
                    .font(TextStyle.body)
                Button("Continue") { self.recoveryKey = nil }
                    .buttonStyle(.primaryLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!confirmedSaved)
            } else {
                VStack(spacing: Space.s) {
                    Text("Keep secrets out of files").font(TextStyle.display).foregroundStyle(Palette.ink)
                    Text("Your vault is one encrypted file on this Mac. The Secure Enclave holds its key and Touch ID opens it. No account, no server.")
                        .font(TextStyle.body).foregroundStyle(Palette.ink2)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                Button {
                    do { recoveryKey = try vault.createVault() } catch { self.error = error.localizedDescription }
                } label: { Label("Create vault", systemImage: "touchid") }
                    .buttonStyle(.primaryLarge)
                    .keyboardShortcut(.defaultAction)
                Button { restoreURL = chooseBackup() } label: { Label("Restore from backup…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.secondary)
                    .help("Moving from another Mac? Open the .redact backup you exported there.")
                if let error { Notice(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger).frame(maxWidth: 420) }
            }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvas()
        .sheet(item: Binding(get: { restoreURL.map { ImportTarget(path: $0.path) } }, set: { restoreURL = $0.map { URL(fileURLWithPath: $0.path) } })) { target in
            RestoreSheet(url: URL(fileURLWithPath: target.path), mode: .newVault)
        }
        .onAppear { takePending() }
        .onChange(of: status.pendingBackup) { takePending() }
    }

    private func takePending() {
        guard let url = status.pendingBackup else { return }
        status.pendingBackup = nil
        restoreURL = url
    }
}

// MARK: - Locked

struct LockedView: View {
    @EnvironmentObject var vault: VaultController
    @State private var showRecovery = false
    @State private var recoveryText = ""

    var body: some View {
        VStack(spacing: Space.xl) {
            RedactMark(size: 64)
            VStack(spacing: Space.s) {
                Text("Redact is locked").font(TextStyle.display).foregroundStyle(Palette.ink)
                Text("Your keys stay encrypted on this Mac until you unlock.")
                    .font(TextStyle.body).foregroundStyle(Palette.ink2)
            }
            VStack(spacing: Space.m) {
                Button {
                    Task { await vault.unlock() }
                } label: { Label("Unlock with Touch ID", systemImage: "touchid") }
                    .buttonStyle(.primaryLarge)
                    .keyboardShortcut(.defaultAction)
                if let error = vault.lastError {
                    Notice(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger).frame(maxWidth: 420)
                }
                Button(showRecovery ? "Hide Recovery Key" : "Use Recovery Key…") { showRecovery.toggle() }
                    .buttonStyle(.quiet)
            }
            if showRecovery {
                HStack(spacing: Space.s) {
                    Field(placeholder: "XXXX-XXXX-…", text: $recoveryText, secure: true, mono: true)
                        .frame(width: 380)
                        .onSubmit(unlockWithRecovery)
                    Button("Unlock", action: unlockWithRecovery)
                        .buttonStyle(.secondary)
                        .disabled(recoveryText.isEmpty)
                }
            }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvas()
    }

    private func unlockWithRecovery() {
        if vault.unlock(recoveryKey: recoveryText) { recoveryText = "" }
    }
}

// MARK: - Main

struct MainView: View {
    @EnvironmentObject var vault: VaultController
    @EnvironmentObject var status: AppStatus
    @State private var restoreURL: URL?
    @State private var destination: Destination? = .section(.projects)
    @State private var showPaste = false
    @State private var showTerminalSetup = false
    @State private var importRoot: String?

    private var projects: [Project] {
        vault.data.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .canvas()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StatusBar(showActivity: { destination = .section(.activity) })
                }
        }
        .toolbar(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showPaste) { pasteSheet }
        .sheet(isPresented: $showTerminalSetup) { TerminalSetupView() }
        .sheet(item: Binding(get: { restoreURL.map { ImportTarget(path: $0.path) } }, set: { restoreURL = $0.map { URL(fileURLWithPath: $0.path) } })) { target in
            RestoreSheet(url: URL(fileURLWithPath: target.path), mode: .merge)
        }
        .onAppear { takePendingBackup() }
        .onChange(of: status.pendingBackup) { takePendingBackup() }
        .sheet(item: Binding(get: { importRoot.map(ImportTarget.init) }, set: { importRoot = $0?.path })) { target in
            ImportSheet(root: target.path) { projectID in destination = .project(projectID) }
        }
        .background {
            // ⌘1–⌘6 section shortcuts.
            ForEach(Section.allCases) { s in
                Button("") { destination = .section(s) }.keyboardShortcut(s.shortcut).hidden()
            }
            // ⌘N: paste a secret into whatever is on screen.
            Button("") { showPaste = true }.keyboardShortcut("n").hidden()
            // ⌘F: find.
            Button("") { NotificationCenter.default.post(name: .redactQuickFind, object: nil) }.keyboardShortcut("f").hidden()
        }
        .onContinuousHover { _ in vault.touch() }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevSelect)) { note in
            destination = (note.object as? String).flatMap(Section.init(rawValue:)).map(Destination.section)
        }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevSelectFirst)) { _ in
            if destination == .section(.projects), let first = projects.first { destination = .project(first.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevImport)) { note in importRoot = note.object as? String }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevPaste)) { _ in showPaste.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .redactDevRestore)) { note in restoreURL = note.object as? URL }
        .onReceive(NotificationCenter.default.publisher(for: .redactShowTerminalSetup)) { _ in showTerminalSetup = true }
    }

    private func takePendingBackup() {
        guard let url = status.pendingBackup else { return }
        status.pendingBackup = nil
        restoreURL = url
    }

    /// ⌘N adds to what's on screen: a variable in the open project, codes on the codes page, a key elsewhere.
    @ViewBuilder private var pasteSheet: some View {
        switch destination {
        case let .project(id): PasteSheet(kind: .variable, projectID: id)
        case .section(.codes): PasteSheet(kind: .backupCodes)
        default: PasteSheet()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $destination) {
            ForEach([Section.projects, .keys, .codes, .identities]) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(badge(for: section))
                    .tag(Destination.section(section))
            }

            SwiftUI.Section {
                ForEach(projects) { project in
                    Label(project.name, systemImage: "folder")
                        .badge(vault.data.items.filter { $0.kind == .variable && $0.projectID == project.id }.count)
                        .tag(Destination.project(project.id))
                        .help(abbreviate(project.path))
                        .contextMenu { projectMenu(project) }
                }
                if projects.isEmpty {
                    Button { chooseFolder() } label: { Label("Add a folder…", systemImage: "plus") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.ink2)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button { chooseFolder() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("Add a project folder")
                        .accessibilityLabel("Add a project folder")
                }
            }

            SwiftUI.Section("Safety") {
                ForEach([Section.health, .activity, .backup]) { section in
                    Label(section.title, systemImage: section.icon).tag(Destination.section(section))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    RedactMark(size: 24)
                    Text("Redact").font(TextStyle.heading).foregroundStyle(Palette.ink)
                    Spacer()
                }
                CommandPill()
            }
            .padding(.horizontal, Space.m)
            .padding(.top, 28) // clears the traffic lights
            .padding(.bottom, Space.s)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VaultStatusCard { vault.lock() }
                .padding(Space.m)
        }
    }

    private func badge(for section: Section) -> Int {
        switch section {
        case .keys: vault.data.items.filter { $0.kind == .apiKey }.count
        case .codes: vault.data.items.filter { $0.kind == .backupCodes }.count
        case .identities: vault.data.identities.count
        default: 0
        }
    }

    @ViewBuilder private func projectMenu(_ project: Project) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
        Button("Re-scan env files…") { importRoot = project.path }
        Divider()
        Button("Remove project…", role: .destructive) { remove(project) }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch destination ?? .section(.projects) {
        case .section(.projects):
            ProjectsOverview(open: { destination = .project($0) }, add: chooseFolder, importFolder: { importRoot = $0 })
        case let .project(id):
            if let project = vault.data.projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project, rescan: { importRoot = project.path })
                    .id(project.id)
            } else {
                ProjectsOverview(open: { destination = .project($0) }, add: chooseFolder, importFolder: { importRoot = $0 })
            }
        case .section(.keys): KeysView(kind: .apiKey)
        case .section(.codes): KeysView(kind: .backupCodes)
        case .section(.identities): IdentitiesView()
        case .section(.health): HealthView()
        case .section(.activity): ActivityView()
        case .section(.backup): BackupView()
        }
    }

    // MARK: Actions

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
        if destination == .project(project.id) { destination = .section(.projects) }
    }
}

/// Reaches the hosting NSWindow for settings SwiftUI doesn't expose on macOS 14.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Toolbar search pill: opens Quick find from anywhere in the window.
struct CommandPill: View {
    @State private var hovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .redactQuickFind, object: nil)
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                Text("Find").font(TextStyle.small)
                Spacer(minLength: Space.s)
                Text("⌥⌘K").font(TextStyle.caption).monospacedDigit()
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(Palette.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .foregroundStyle(Palette.ink2)
            .padding(.leading, Space.m)
            .padding(.trailing, Space.xs)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(hovering ? Palette.selected : Palette.hover, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Quick find: ⌘F here, ⌥⌘K from any app")
        .onHover { hovering = $0 }
    }
}

/// Sidebar footer: the lock button.
struct VaultStatusCard: View {
    let lock: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: lock) {
            HStack(spacing: Space.s) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                Text("Lock vault").font(TextStyle.smallStrong)
                Spacer()
                Text("⌃⌘L").font(TextStyle.caption).foregroundStyle(Palette.ink2)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.m)
            .frame(height: 32)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .background(hovering ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Lock now. Agents get nothing until you unlock again.")
        .onHover { hovering = $0 }
    }
}

// MARK: - Status bar

/// Bottom bar: what the vault, the agent socket and the LLM proxy are doing right now.
struct StatusBar: View {
    @EnvironmentObject var vault: VaultController
    @EnvironmentObject var approvals: ApprovalCenter
    @EnvironmentObject var status: AppStatus
    let showActivity: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Space.m) {
                item("lock.open.fill", "Unlocked", tone: .accent)
                    .help("Locks after \(Int(vault.idleLimit / 60)) minutes idle, on sleep, and when the screen locks")
                item("timer", "Auto-lock in \(autoLock(at: context.date))")
                divider
                item(status.socketReady ? "point.3.connected.trianglepath.dotted" : "exclamationmark.triangle.fill",
                     status.socketReady ? "Agents can connect" : "Agent socket off",
                     tone: status.socketReady ? .neutral : .danger)
                    .help(status.socketReady ? "The `redact` CLI and MCP server talk to this app over a local socket only you can open"
                          : "The CLI can't reach Redact. Quit and reopen the app.")
                let sessions = status.llmProxy.activeSessionCount
                if sessions > 0 {
                    item("arrow.left.arrow.right", "LLM proxy: \(sessions) session\(sessions == 1 ? "" : "s")", tone: .ok)
                        .help("Agents are using placeholder keys; the proxy swaps in the real key on 127.0.0.1")
                }
                let grants = approvals.activeGrants.count
                if grants > 0 {
                    Button(action: showActivity) {
                        item("clock.badge.checkmark", "\(grants) open grant\(grants == 1 ? "" : "s")", tone: .warning)
                    }
                    .buttonStyle(.plain)
                    .help("An agent can run without asking until its grant ends. Open Activity to revoke.")
                }
                if let clears = Clipboard.pendingClear {
                    item("doc.on.clipboard", "Clipboard clears in \(max(Int(clears.timeIntervalSince(context.date).rounded(.up)), 0)) s")
                }
                Spacer(minLength: Space.m)
                if let last = vault.data.activity.first {
                    Text("Last run \(Ago.text(last.date)) by \(last.agent ?? "you")")
                        .font(TextStyle.caption)
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                        .help(last.command)
                }
            }
            .padding(.horizontal, Space.m)
            .frame(height: 26)
            .background(.bar)
            .overlay(alignment: .top) { Rule() }
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.rule).frame(width: 1, height: 12)
    }

    private func autoLock(at now: Date) -> String {
        let remaining = max(vault.idleLimit - now.timeIntervalSince(vault.lastActivity), 0)
        return remaining >= 60 ? "\(Int((remaining / 60).rounded(.up))) min" : "\(Int(remaining)) s"
    }

    private func item(_ symbol: String, _ text: String, tone: Tone = .neutral) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(color(tone))
            Text(text).font(TextStyle.caption).monospacedDigit().foregroundStyle(tone == .neutral ? Palette.ink2 : Palette.ink)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func color(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: Palette.ink3
        case .accent: Palette.accentText
        case .ok: Palette.ok
        case .warning: Palette.warning
        case .danger: Palette.danger
        }
    }
}
