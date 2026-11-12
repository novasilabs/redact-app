import AppKit
import RedactCore
import SwiftUI

/// Dev-only: renders each screen of the app to PNG files, then quits.
///
/// Active only when both `REDACT_HOME` (a test vault) and `REDACT_SNAPSHOT_DIR` are set. It draws the
/// app's own windows into bitmaps, so it needs no screen-recording permission.
@MainActor
enum DevSnapshot {
    static var directory: URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["REDACT_HOME"] != nil, let dir = env["REDACT_SNAPSHOT_DIR"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    /// `REDACT_SNAPSHOT_PATH_ALIAS=/real/prefix=~/code`: shows demo folders under a friendlier path.
    nonisolated static let pathAlias: (from: String, to: String)? = {
        let env = ProcessInfo.processInfo.environment
        guard env["REDACT_SNAPSHOT_DIR"] != nil, let raw = env["REDACT_SNAPSHOT_PATH_ALIAS"],
              let eq = raw.firstIndex(of: "=") else { return nil }
        return (String(raw[..<eq]), String(raw[raw.index(after: eq)...]))
    }()

    static func run(vault: VaultController, approvals: ApprovalCenter) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch ProcessInfo.processInfo.environment["REDACT_SNAPSHOT_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // REDACT_SNAPSHOT_SIZE=1200x760 (points) resizes the main window before capturing.
            if let size = ProcessInfo.processInfo.environment["REDACT_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
               size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
            }
            try? await Task.sleep(for: .seconds(0.5))
            capture("01-locked", to: directory)
            _ = await vault.unlock()
            try? await Task.sleep(for: .seconds(1))

            for section in Section.allCases {
                NotificationCenter.default.post(name: .redactDevSelect, object: section.rawValue)
                try? await Task.sleep(for: .seconds(1))
                capture("02-\(section.rawValue.lowercased())", to: directory)
                // Also show the first item's detail view.
                NotificationCenter.default.post(name: .redactDevSelectFirst, object: nil)
                try? await Task.sleep(for: .seconds(1))
                capture("03-\(section.rawValue.lowercased())-detail", to: directory)
            }

            NotificationCenter.default.post(name: .redactDevSelect, object: Section.projects.rawValue)
            try? await Task.sleep(for: .seconds(0.5))
            if let project = vault.data.projects.first {
                NotificationCenter.default.post(name: .redactDevImport, object: project.path)
                try? await Task.sleep(for: .seconds(1.5))
                capture("04-import-sheet", to: directory)
                NotificationCenter.default.post(name: .redactDevImport, object: nil)
                try? await Task.sleep(for: .seconds(0.5))
            }

            NotificationCenter.default.post(name: .redactDevPaste, object: nil)
            try? await Task.sleep(for: .seconds(1))
            capture("05-paste-sheet", to: directory)
            NotificationCenter.default.post(name: .redactDevPaste, object: nil)
            try? await Task.sleep(for: .seconds(0.5))

            let approvalTask = Task {
                await approvals.ask(ApprovalRequest(
                    agent: "Claude Code", command: "npx wrangler deploy --env production",
                    directory: vault.data.projects.first?.path ?? "/", project: vault.data.projects.first?.name ?? "demo",
                    environment: "production", variableNames: ["DATABASE_URL", "OPENAI_API_KEY", "STRIPE_SECRET_KEY"],
                    callerPath: "/Users/dev/.local/bin/redact", callerChain: "zsh ← claude ← Claude",
                    callerSigned: "Signature: dev.redact.cli"))
            }
            try? await Task.sleep(for: .seconds(1))
            capture("06-approval-panel", to: directory)
            approvals.dismissForSnapshot()
            _ = await approvalTask.value

            if let backup = try? vault.makeBackup(.all(vault.data)) {
                let url = directory.appendingPathComponent("snapshot-backup.redact")
                try? backup.write(to: url)
                NotificationCenter.default.post(name: .redactDevRestore, object: url)
                try? await Task.sleep(for: .seconds(1))
                capture("08-restore-sheet", to: directory)
                NotificationCenter.default.post(name: .redactDevRestore, object: nil)
                try? await Task.sleep(for: .seconds(0.5))
            }

            NotificationCenter.default.post(name: .redactQuickFind, object: nil)
            try? await Task.sleep(for: .seconds(1))
            capture("07-quick-find", to: directory)

            vault.lock()
            NSApp.terminate(nil)
        }
    }

    /// Draws every visible window of this app into one PNG per window.
    static func capture(_ name: String, to directory: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 80 && $0.frame.height > 80 }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let suffix = windows.count > 1 ? "-w\(index)" : ""
            try? png.write(to: directory.appendingPathComponent("\(name)\(suffix).png"))
        }
    }
}

extension Notification.Name {
    static let redactDevSelect = Notification.Name("redactDevSelect")
    static let redactDevSelectFirst = Notification.Name("redactDevSelectFirst")
    static let redactDevImport = Notification.Name("redactDevImport")
    static let redactDevPaste = Notification.Name("redactDevPaste")
    static let redactDevRestore = Notification.Name("redactDevRestore")
}
