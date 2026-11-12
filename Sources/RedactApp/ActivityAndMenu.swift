import Carbon.HIToolbox
import RedactCore
import SwiftUI

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var vault: VaultController
    @EnvironmentObject var approvals: ApprovalCenter

    static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !approvals.activeGrants.isEmpty {
                HStack {
                    VStack(alignment: .leading) {
                        ForEach(approvals.activeGrants, id: \.until) { grant in
                            Text("\(grant.agent) can use \(abbreviate(grant.project)) · \(grant.environment) until \(grant.until.formatted(date: .omitted, time: .shortened))")
                                .font(.callout)
                        }
                    }
                    Spacer()
                    Button("Revoke all") { approvals.revokeAll() }
                }
                .padding(12)
                .background(.yellow.opacity(0.12))
            }
            Table(vault.data.activity) {
                TableColumn("When") { entry in
                    Text(Self.ago.localizedString(for: entry.date, relativeTo: Date()))
                        .foregroundStyle(.secondary)
                        .help(entry.date.formatted(date: .abbreviated, time: .standard))
                }
                .width(90)
                TableColumn("Who") { entry in Text(entry.agent ?? entry.caller) }.width(110)
                TableColumn("Command") { entry in Text(entry.command).font(.callout.monospaced()).lineLimit(1).help(entry.command) }
                TableColumn("Variables") { entry in Text(entry.variableNames.joined(separator: ", ")).font(.caption.monospaced()).lineLimit(1) }
                TableColumn("Result") { entry in
                    switch entry.outcome {
                    case .approved: Text("approved").foregroundStyle(.green)
                    case .autoApproved: Text("you").foregroundStyle(.secondary)
                    case .denied: Text("denied").foregroundStyle(.red)
                    case .failed: Text("failed").foregroundStyle(.orange)
                    case .granted: Text("15-min grant").foregroundStyle(.green)
                    }
                }
                .width(80)
            }
        }
        .navigationTitle("Activity")
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var vault: VaultController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if vault.state == .unlocked {
            Text("Unlocked")
            Button("Lock now") { vault.lock() }.keyboardShortcut("l")
        } else if vault.state == .locked {
            Text("Locked")
            Button("Unlock…") { Task { await vault.unlock() } }
        }
        Divider()
        Button("Quick find  ⌥⌘K") { NotificationCenter.default.post(name: .redactQuickFind, object: nil) }
            .disabled(vault.state != .unlocked)
        Button("Open Redact") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Redact") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

extension Notification.Name {
    static let redactQuickFind = Notification.Name("redactQuickFind")
}

// MARK: - Quick find (⌥⌘K)

@MainActor
final class QuickFindController {
    private let vault: VaultController
    private var panel: NSPanel?

    init(vault: VaultController) {
        self.vault = vault
        NotificationCenter.default.addObserver(forName: .redactQuickFind, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.toggle() }
        }
    }

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        Task {
            guard await vault.unlock(reason: "find a secret") else { return }
            show()
        }
    }

    private func show() {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                                 styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: QuickFindView(close: { [weak self] in self?.close() }).environmentObject(vault))
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.close()
        panel = nil
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickFindView: View {
    @EnvironmentObject var vault: VaultController
    let close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @State private var copied: String?
    @FocusState private var focused: Bool

    struct Hit: Identifiable {
        let id: UUID
        let title: String
        let subtitle: String
        let value: String
    }

    var hits: [Hit] {
        let all: [Hit] = vault.data.items.compactMap { item in
            switch item.kind {
            case .backupCodes:
                guard let code = item.codes.first(where: { $0.usedAt == nil }) else { return nil }
                return Hit(id: item.id, title: item.name, subtitle: "next backup code", value: code.code)
            case .variable:
                let project = vault.data.projects.first { $0.id == item.projectID }?.name ?? ""
                return Hit(id: item.id, title: item.name, subtitle: "\(project) · \(item.environment ?? "")", value: vault.data.resolvedValue(of: item))
            default:
                return Hit(id: item.id, title: item.name, subtitle: item.kind == .note ? "note" : "key", value: item.value)
            }
        }
        guard !query.isEmpty else { return Array(all.prefix(8)) }
        let terms = query.lowercased().split(separator: " ")
        return all.filter { hit in terms.allSatisfy { (hit.title + " " + hit.subtitle).lowercased().contains($0) } }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Find a key, variable or code…", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(16)
                .focused($focused)
                .onSubmit(copySelected)
                .onChange(of: query) { selected = 0 }
            Divider()
            if let copied {
                Text("Copied \(copied). Clears in 60 s.").foregroundStyle(.secondary).padding()
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title).font(EnvFile.isValidName(hit.title) ? .body.monospaced() : .body)
                                Text(hit.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(index == selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { selected = index; copySelected() }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 560, height: 360)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(hits.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func copySelected() {
        let current = hits
        guard current.indices.contains(selected) else { return }
        let hit = current[selected]
        Clipboard.copy(hit.value)
        // Copying a backup code marks it used.
        if let item = vault.data.items.first(where: { $0.id == hit.id }), item.kind == .backupCodes,
           let index = item.codes.firstIndex(where: { $0.usedAt == nil }) {
            vault.update { data in
                if let i = data.items.firstIndex(where: { $0.id == item.id }) { data.items[i].codes[index].usedAt = Date() }
            }
        }
        copied = hit.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }
    }
}

// MARK: - Global hotkey (Carbon, no accessibility permission needed)

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.action = action
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x5244_4354), id: 1) // 'RDCT'
        RegisterEventHotKey(keyCode, carbonModifiers, id, GetApplicationEventTarget(), 0, &reference)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
