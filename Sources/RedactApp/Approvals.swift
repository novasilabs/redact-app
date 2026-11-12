import AppKit
import LocalAuthentication
import RedactCore
import SwiftUI

struct ApprovalRequest: Identifiable {
    let id = UUID()
    var agent: String
    var command: String
    var directory: String
    var project: String
    var environment: String
    var variableNames: [String]
    var callerPath: String
    var callerChain: String
    var callerSigned: String
    /// Time-boxed grants only make sense for running commands, not for vault changes.
    var allowsGrant: Bool = true
}

enum ApprovalDecision { case deny, once, fifteenMinutes }

/// Shows approval panels for agent requests and remembers time-boxed grants.
@MainActor
final class ApprovalCenter: ObservableObject {
    private struct GrantKey: Hashable { var agent: String; var projectPath: String; var environment: String }
    private var grants: [GrantKey: Date] = [:]
    private var panel: NSPanel?

    init() {
        NotificationCenter.default.addObserver(forName: .redactDidLock, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.grants.removeAll() }
        }
    }

    var activeGrants: [(agent: String, project: String, environment: String, until: Date)] {
        grants.filter { $0.value > Date() }
            .map { (agent: $0.key.agent, project: $0.key.projectPath, environment: $0.key.environment, until: $0.value) }
            .sorted { $0.until < $1.until }
    }

    func revokeAll() { grants.removeAll() }

    func hasGrant(agent: String, projectPath: String, environment: String) -> Bool {
        let key = GrantKey(agent: agent, projectPath: projectPath, environment: environment)
        guard let until = grants[key] else { return false }
        if until < Date() { grants.removeValue(forKey: key); return false }
        return true
    }

    func addGrant(agent: String, projectPath: String, environment: String, minutes: Double) {
        grants[GrantKey(agent: agent, projectPath: projectPath, environment: environment)] = Date().addingTimeInterval(minutes * 60)
        objectWillChange.send()
    }

    /// Shows the panel and waits for a decision.
    func ask(_ request: ApprovalRequest) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish: (ApprovalDecision) -> Void = { [weak self] decision in
                guard !finished else { return }
                finished = true
                self?.panel?.close()
                self?.panel = nil
                continuation.resume(returning: decision)
            }
            let view = ApprovalView(request: request, decide: finish)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                                styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.title = "Redact"
            panel.titlebarAppearsTransparent = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: view)
            panel.center()
            self.panel?.close()
            self.panel = panel
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Touch ID (or Mac password) confirmation for an approval made while already unlocked.
    func confirmWithOwner(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

struct ApprovalView: View {
    let request: ApprovalRequest
    let decide: (ApprovalDecision) -> Void
    @State private var showCaller = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.agent) wants to use your secrets")
                        .font(.headline)
                    Text("\(request.project) · \(request.environment)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                Text(request.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Text("Variables (\(request.variableNames.count))").font(.caption).foregroundStyle(.secondary)
                Text(request.variableNames.isEmpty ? "none" : request.variableNames.joined(separator: ", "))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(3)
            }

            DisclosureGroup("Caller details", isExpanded: $showCaller) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.callerPath).font(.caption.monospaced()).textSelection(.enabled)
                    Text(request.callerChain).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(request.callerSigned).font(.caption).foregroundStyle(.secondary)
                    Text(request.directory).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            Text("Approving gives this command the values. Output is masked, but the command itself can use them however it likes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Deny", role: .cancel) { decide(.deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if request.allowsGrant {
                    Button("Allow for 15 min") { decide(.fifteenMinutes) }
                }
                Button("Allow once") { decide(.once) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
