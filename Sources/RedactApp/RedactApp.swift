import AppKit
import RedactCore
import SwiftUI

@main
struct RedactApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Redact", id: "main") {
            RootView()
                .environmentObject(delegate.vault)
                .environmentObject(delegate.approvals)
                .environmentObject(delegate.status)
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Lock Redact") { delegate.vault.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(delegate.vault)
                .environmentObject(delegate.approvals)
        } label: {
            Image(systemName: delegate.vault.state == .unlocked ? "lock.open" : "lock")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let vault = VaultController()
    let approvals = ApprovalCenter()
    let llmProxy = LLMProxy()
    lazy var status = AppStatus(llmProxy: llmProxy)
    private var server: BrokerServer?
    private var hotKey: HotKey?
    private lazy var quickFind = QuickFindController(vault: vault)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let handler = BrokerHandler(vault: vault, approvals: approvals, llmProxy: llmProxy)
        // Placeholders stop working the moment the vault locks.
        NotificationCenter.default.addObserver(forName: .redactDidLock, object: nil, queue: .main) { [llmProxy] _ in
            llmProxy.endAll()
        }
        let server = BrokerServer { request, peer in
            await handler.handle(request, peer: peer)
        }
        do {
            try server.start()
            self.server = server
            status.socketReady = true
        } catch {
            vault.lastError = "Couldn't start the agent socket: \(error.localizedDescription)"
        }
        // ⌥⌘K: quick find from anywhere.
        hotKey = HotKey(keyCode: 40, modifiers: [.option, .command]) { [weak self] in
            Task { @MainActor in self?.quickFind.toggle() }
        }
        _ = quickFind // listen for menu bar "Quick find"
        DevSnapshot.run(vault: vault, approvals: approvals)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        llmProxy.stop()
        vault.lock()
    }

    /// Double-clicked `.redact` backups open the restore sheet.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == "redact" }) else { return }
        status.pendingBackup = url
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Live app state for the status bar.
@MainActor
final class AppStatus: ObservableObject {
    @Published var socketReady = false
    /// A backup file the user opened from Finder, waiting for the restore sheet.
    @Published var pendingBackup: URL?
    let llmProxy: LLMProxy

    init(llmProxy: LLMProxy) { self.llmProxy = llmProxy }
}
