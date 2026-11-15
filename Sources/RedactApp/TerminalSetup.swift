import AppKit
import SwiftUI

/// Puts the `redact` command on the user's PATH and the shell hook in their shell config, for people
/// who installed from the .dmg (no install script).
@MainActor
final class TerminalSetup: ObservableObject {
    static let shared = TerminalSetup()

    enum CLIState: Equatable { case installed, elsewhere(String), missing }

    @Published private(set) var cli: CLIState = .missing
    @Published private(set) var missingShellLines: [String] = []
    @Published var error: String?

    let binDirectory = NSHomeDirectory() + "/.local/bin"
    var linkPath: String { binDirectory + "/redact" }
    var bundledCLI: String { Bundle.main.bundlePath + "/Contents/Resources/bin/redact" }

    var shell: String { (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?.lastPathComponent ?? "zsh" }
    /// The file Redact adds its lines to.
    var rcFile: String { NSHomeDirectory() + (shell == "bash" ? "/.bashrc" : "/.zshrc") }
    var rcName: String { (rcFile as NSString).abbreviatingWithTildeInPath }

    var isComplete: Bool { cli == .installed && missingShellLines.isEmpty }

    static let marker = "# Added by Redact"

    func refresh() {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
            cli = (target as NSString).standardizingPath == (bundledCLI as NSString).standardizingPath ? .installed : .elsewhere(target)
        } else {
            cli = fm.fileExists(atPath: linkPath) ? .elsewhere(linkPath) : .missing
        }
        // Read every file a shell might set PATH in; the hook only in the rc file.
        let configs = [rcFile, NSHomeDirectory() + "/.zprofile", NSHomeDirectory() + "/.zshenv",
                       NSHomeDirectory() + "/.bash_profile", NSHomeDirectory() + "/.profile"]
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined(separator: "\n")
        let rc = (try? String(contentsOfFile: rcFile, encoding: .utf8)) ?? ""
        var lines: [String] = []
        if !configs.contains(".local/bin") { lines.append(#"export PATH="$HOME/.local/bin:$PATH""#) }
        if !rc.contains("redact hook") { lines.append(#"eval "$(redact hook \#(shell == "bash" ? "bash" : "zsh"))""#) }
        missingShellLines = lines
    }

    /// Links ~/.local/bin/redact to the CLI inside this app (replacing a link to an older copy).
    func installCLI() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil {
                try fm.removeItem(atPath: linkPath)
            } else if fm.fileExists(atPath: linkPath) {
                error = "\((linkPath as NSString).abbreviatingWithTildeInPath) is a file, not a link Redact made. Move it away, then try again."
                return
            }
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: bundledCLI)
            error = nil
        } catch {
            self.error = "Couldn't install the command: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Appends the missing lines to the shell config, marked so they're easy to find and remove.
    func addToShell() {
        guard !missingShellLines.isEmpty else { return }
        let block = "\n\(Self.marker): the redact command and its shell integration\n" + missingShellLines.joined(separator: "\n") + "\n"
        do {
            if let handle = FileHandle(forWritingAtPath: rcFile) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(block.utf8))
            } else {
                try block.write(toFile: rcFile, atomically: true, encoding: .utf8)
            }
            error = nil
        } catch {
            self.error = "Couldn't update \(rcName): \(error.localizedDescription)"
        }
        refresh()
    }
}

/// Three steps: the command, the shell, and (optionally) Claude Code.
struct TerminalSetupView: View {
    @ObservedObject private var setup = TerminalSetup.shared
    @Environment(\.dismiss) private var dismiss
    private let mcpCommand = "claude mcp add --scope user redact -- ~/.local/bin/redact mcp"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.m) {
                RedactMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up your terminal").font(TextStyle.title).foregroundStyle(Palette.ink)
                    Text("So `rr npm run dev` works in any project folder.").font(TextStyle.small).foregroundStyle(Palette.ink2)
                }
            }

            VStack(spacing: 0) {
                step(1, title: "The redact command", detail: cliDetail, done: setup.cli == .installed) {
                    Button(setup.cli == .missing ? "Install" : "Reinstall") { setup.installCLI() }.buttonStyle(.secondary)
                }
                Rule(inset: 52)
                step(2, title: "Your shell", detail: shellDetail, done: setup.missingShellLines.isEmpty) {
                    Button("Add to \(setup.rcName)") { setup.addToShell() }.buttonStyle(.secondary)
                }
                Rule(inset: 52)
                step(3, title: "Claude Code (optional)", detail: "Lets Claude Code ask Redact for variable names (never values).", done: false) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpCommand, forType: .string)
                    } label: { Label("Copy command", systemImage: "doc.on.doc") }
                        .buttonStyle(.quiet)
                }
            }
            .card()

            if let error = setup.error { Notice(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger) }
            if !setup.missingShellLines.isEmpty {
                Text("Adds to \(setup.rcName):\n" + setup.missingShellLines.joined(separator: "\n"))
                    .font(TextStyle.monoSmall).foregroundStyle(Palette.ink2).textSelection(.enabled)
                    .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading).sunken(radius: Radius.card)
            }
            HStack {
                if setup.isComplete {
                    Text("Open a new terminal tab to start using it.").font(TextStyle.small).foregroundStyle(Palette.ink2)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 600)
        .canvas()
        .onAppear { setup.refresh() }
    }

    private var cliDetail: String {
        switch setup.cli {
        case .installed: "~/.local/bin/redact points to this app."
        case .elsewhere(let path): "~/.local/bin/redact points to another copy (\((path as NSString).abbreviatingWithTildeInPath))."
        case .missing: "Links ~/.local/bin/redact to the command inside Redact.app. No admin password."
        }
    }

    private var shellDetail: String {
        setup.missingShellLines.isEmpty
            ? "\(setup.rcName) has ~/.local/bin on the PATH and the Redact hook (shows the project when you cd, adds rr)."
            : "Adds ~/.local/bin to the PATH and the Redact hook to \(setup.rcName)."
    }

    private func step<Action: View>(_ number: Int, title: String, detail: String, done: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: Space.m) {
            ZStack {
                Circle().fill(done ? Palette.accent : Palette.sunken).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accentInk)
                } else {
                    Text("\(number)").font(TextStyle.caption.weight(.semibold)).foregroundStyle(Palette.ink2)
                }
            }
            .accessibilityLabel(done ? "Done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TextStyle.bodyStrong).foregroundStyle(Palette.ink)
                Text(detail).font(TextStyle.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            if !done { action() }
        }
        .padding(Space.m)
    }
}

extension Notification.Name {
    static let redactShowTerminalSetup = Notification.Name("redactShowTerminalSetup")
}
