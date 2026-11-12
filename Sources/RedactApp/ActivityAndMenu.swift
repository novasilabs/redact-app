import Carbon.HIToolbox
import RedactCore
import SwiftUI

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var vault: VaultController
    @EnvironmentObject var approvals: ApprovalCenter

    static var ago: RelativeDateTimeFormatter { Ago.formatter }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                PageHeader(title: "Activity",
                           subtitle: "Every time a command got your secrets: who asked, what ran, and what you decided.")

                if !approvals.activeGrants.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        GroupLabel(title: "Open grants") {
                            Button("Revoke all") { approvals.revokeAll() }.buttonStyle(.danger)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(approvals.activeGrants.enumerated()), id: \.offset) { index, grant in
                                if index > 0 { Rule(inset: 48) }
                                HStack(spacing: Space.m) {
                                    BrandTile(brand: .ofAgent(grant.agent), size: 24)
                                    Text(grant.agent).font(TextStyle.bodyStrong)
                                    PathLabel(path: grant.project)
                                    Pill(text: grant.environment, symbol: grant.environment == "production" ? "bolt.fill" : nil,
                                         tone: grant.environment == "production" ? .warning : .neutral)
                                    Spacer()
                                    Text("until \(grant.until.formatted(date: .omitted, time: .shortened))")
                                        .font(TextStyle.small).monospacedDigit().foregroundStyle(Palette.ink2)
                                }
                                .padding(.horizontal, Space.m)
                                .frame(minHeight: 44)
                            }
                        }
                        .card()
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(vault.data.activity.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Rule(inset: 52) }
                        ActivityRow(entry: entry)
                    }
                    if vault.data.activity.isEmpty {
                        EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing yet",
                                   message: "When you or an agent runs `redact run`, it shows up here.")
                    }
                }
                .card()
            }
            .padding(Space.xl)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            BrandTile(brand: .ofAgent(entry.agent), size: 28, symbol: "person.fill")
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(entry.command)
                    .font(TextStyle.monoStrong)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.command)
                HStack(spacing: Space.s) {
                    Text(entry.agent ?? "You").font(TextStyle.small).foregroundStyle(Palette.ink2)
                    Text(Ago.text(entry.date)).font(TextStyle.small).monospacedDigit().foregroundStyle(Palette.ink2)
                        .help(entry.date.formatted(date: .abbreviated, time: .standard))
                    ForEach(entry.variableNames.prefix(3), id: \.self) { name in Pill(text: name, mono: true) }
                    if entry.variableNames.count > 3 {
                        Pill(text: "+\(entry.variableNames.count - 3)")
                            .help(entry.variableNames.dropFirst(3).joined(separator: ", "))
                    }
                }
            }
            Spacer(minLength: Space.s)
            outcome
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var outcome: some View {
        switch entry.outcome {
        case .approved: Pill(text: "Approved", symbol: "checkmark", tone: .ok)
        case .autoApproved: Pill(text: "Ran by you", symbol: "person.fill")
        case .denied: Pill(text: "Denied", symbol: "xmark", tone: .danger)
        case .failed: Pill(text: "Failed", symbol: "exclamationmark.triangle.fill", tone: .warning)
        case .granted: Pill(text: "15-min grant", symbol: "clock", tone: .ok)
        }
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
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
        var brand: Brand = .generic
        var symbol = "key.fill"
    }

    var hits: [Hit] {
        let all: [Hit] = vault.data.items.compactMap { item in
            switch item.kind {
            case .backupCodes:
                guard let code = item.codes.first(where: { $0.usedAt == nil }) else { return nil }
                return Hit(id: item.id, title: item.name, subtitle: "Next backup code", value: code.code, brand: .of(item), symbol: "list.number")
            case .variable:
                let project = vault.data.projects.first { $0.id == item.projectID }?.name ?? ""
                return Hit(id: item.id, title: item.name, subtitle: "\(project), \(item.environment ?? "")", value: vault.data.resolvedValue(of: item),
                           brand: Brand.of(Item(kind: .apiKey, name: item.name, value: vault.data.resolvedValue(of: item))),
                           symbol: "list.bullet.rectangle")
            default:
                let brand = Brand.of(item)
                return Hit(id: item.id, title: item.name, subtitle: item.kind == .note ? "Note" : (brand == .generic ? "Key" : "\(brand.name) key"),
                           value: item.value, brand: brand, symbol: item.kind == .note ? "note.text" : "key.fill")
            }
        }
        guard !query.isEmpty else { return Array(all.prefix(8)) }
        let terms = query.lowercased().split(separator: " ")
        return all.filter { hit in terms.allSatisfy { (hit.title + " " + hit.subtitle).lowercased().contains($0) } }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.ink3)
                TextField("Find a key, variable or code", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit(copySelected)
                    .onChange(of: query) { selected = 0 }
            }
            .padding(.horizontal, Space.l)
            .frame(height: 52)
            Rule()
            if let copied {
                Notice(symbol: "checkmark.circle.fill", text: "Copied \(copied). The clipboard clears in 60 s.", tone: .ok)
                    .padding(Space.s)
            }
            ScrollView {
                VStack(spacing: Space.hairline) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        HStack(spacing: Space.m) {
                            BrandTile(brand: hit.brand, size: 26, symbol: hit.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title).font(EnvFile.isValidName(hit.title) ? TextStyle.monoStrong : TextStyle.bodyStrong)
                                    .foregroundStyle(Palette.ink).lineLimit(1)
                                Text(hit.subtitle).font(TextStyle.small).foregroundStyle(Palette.ink2).lineLimit(1)
                            }
                            Spacer()
                            if index == selected {
                                Text("↩ Copy").font(TextStyle.captionStrong).foregroundStyle(Palette.ink2)
                            }
                        }
                        .padding(.horizontal, Space.s)
                        .frame(height: 44)
                        .background(index == selected ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { selected = index; copySelected() }
                    }
                    if hits.isEmpty {
                        Text("No matches").font(TextStyle.body).foregroundStyle(Palette.ink2).padding(Space.xl)
                    }
                }
                .padding(Space.s)
            }
            Rule()
            HStack(spacing: Space.l) {
                Text("↑↓ to move").font(TextStyle.caption).foregroundStyle(Palette.ink2)
                Text("↩ to copy").font(TextStyle.caption).foregroundStyle(Palette.ink2)
                Text("esc to close").font(TextStyle.caption).foregroundStyle(Palette.ink2)
                Spacer()
                RedactMark(size: 16)
            }
            .padding(.horizontal, Space.l)
            .frame(height: 32)
        }
        .frame(width: 560, height: 380)
        .background(.regularMaterial)
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
