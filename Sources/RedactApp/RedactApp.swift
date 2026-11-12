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
                .frame(minWidth: 820, minHeight: 520)
        }
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
    private var server: BrokerServer?
    private var hotKey: HotKey?
    private lazy var quickFind = QuickFindController(vault: vault)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let handler = BrokerHandler(vault: vault, approvals: approvals)
        let server = BrokerServer { request, peer in
            await handler.handle(request, peer: peer)
        }
        do {
            try server.start()
            self.server = server
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
        vault.lock()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
