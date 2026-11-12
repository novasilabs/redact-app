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

    private var pendingDecision: ((ApprovalDecision) -> Void)?

    /// Dev snapshots only: closes an open panel as "deny".
    func dismissForSnapshot() { pendingDecision?(.deny) }

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
                self?.pendingDecision = nil
                continuation.resume(returning: decision)
            }
            self.pendingDecision = finish
            let view = ApprovalView(request: request, decide: finish)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                                styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.title = "Redact"
            panel.titleVisibility = .hidden
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
        let production = request.environment == "production"
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.m) {
                BrandTile(brand: .ofAgent(request.agent), size: 36, symbol: "terminal")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.agent) wants to run").font(TextStyle.heading).foregroundStyle(Palette.ink)
                    HStack(spacing: Space.s) {
                        Text(request.project).font(TextStyle.small).foregroundStyle(Palette.ink2)
                        Pill(text: request.environment, symbol: production ? "bolt.fill" : nil, tone: production ? .warning : .neutral)
                    }
                }
            }

            (Text("$ ").foregroundStyle(Palette.ink3) + Text(request.command).foregroundStyle(Palette.ink))
                .font(TextStyle.monoLarge)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.m)
                .sunken(radius: Radius.card)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(request.variableNames.isEmpty ? "No variables" : "Gets \(request.variableNames.count) variable\(request.variableNames.count == 1 ? "" : "s")")
                    .font(TextStyle.smallStrong).foregroundStyle(Palette.ink2)
                FlowChips(names: request.variableNames)
            }

            DisclosureGroup(isExpanded: $showCaller) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(request.callerPath).font(TextStyle.monoSmall).foregroundStyle(Palette.ink).textSelection(.enabled)
                    Text(request.callerChain).font(TextStyle.monoSmall).foregroundStyle(Palette.ink2)
                    Text(request.callerSigned).font(TextStyle.caption).foregroundStyle(Palette.ink2)
                    Text(request.directory).font(TextStyle.monoSmall).foregroundStyle(Palette.ink2)
                }
                .padding(.top, Space.xs)
            } label: {
                Text("Caller details").font(TextStyle.small).foregroundStyle(Palette.ink2)
            }

            Text("Approving gives this command the values. Output is masked, but the command itself can use them however it likes.")
                .font(TextStyle.small)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.s) {
                Button("Deny", role: .cancel) { decide(.deny) }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if request.allowsGrant {
                    Button("Allow for 15 min") { decide(.fifteenMinutes) }.buttonStyle(.secondary)
                }
                Button { decide(.once) } label: { Label("Allow once", systemImage: "touchid") }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
        .background(Palette.canvas)
    }
}

/// Variable names as chips that wrap onto new lines.
struct FlowChips: View {
    let names: [String]

    var body: some View {
        WrapLayout(spacing: Space.xs) {
            ForEach(names, id: \.self) { Pill(text: $0, mono: true) }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
