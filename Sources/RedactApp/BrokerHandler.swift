import Foundation
import RedactCore

/// Answers requests from the `redact` CLI and `redact mcp`.
@MainActor
final class BrokerHandler {
    let vault: VaultController
    let approvals: ApprovalCenter

    init(vault: VaultController, approvals: ApprovalCenter) {
        self.vault = vault
        self.approvals = approvals
    }

    func handle(_ request: BrokerRequest, peer: PeerIdentity) async -> BrokerResponse {
        switch request.op {
        case .status: return status(request)
        case .lock:
            vault.lock()
            return BrokerResponse(ok: true)
        case .unlock:
            guard vault.state != .noVault else { return .failure(Self.noVaultMessage) }
            return await vault.unlock() ? status(request) : .failure(vault.lastError ?? "Unlock failed.")
        case .identities: return identities(request)
        case .bindIdentity: return await bindIdentity(request)
        default: break
        }

        // Everything below needs the vault open.
        guard vault.state != .noVault else { return .failure(Self.noVaultMessage) }
        let agent = request.viaMCP == true ? (peer.agentGuess ?? "An MCP agent") : peer.agentGuess

        if request.op == .resolve {
            return await resolve(request, peer: peer, agent: agent)
        }
        if vault.state == .locked {
            let reason = agent.map { "let \($0) use Redact" } ?? "unlock your Redact vault"
            guard await vault.unlock(reason: reason) else { return .failure(vault.lastError ?? "Vault is locked.") }
        }
        vault.touch()

        // Agents must not change the vault on their own: they could replace a key with one they control.
        if let agent, [.set, .remove, .importFolder, .initProject].contains(request.op) {
            if request.viaMCP == true { return .failure("Agents can't change the vault. Ask the user to do it in Redact.") }
            let action: String
            switch request.op {
            case .set: action = "redact set \(request.name ?? "")\(request.environment.map { " --env \($0)" } ?? "")"
            case .remove: action = "redact rm \(request.name ?? "")\(request.environment.map { " --env \($0)" } ?? "")"
            case .importFolder: action = "redact import \(request.path ?? request.cwd)"
            default: action = "redact init \(request.path ?? request.cwd)"
            }
            let preview = previewForApproval(request)
            let decision = await approvals.ask(ApprovalRequest(
                agent: agent, command: action, directory: request.cwd, project: preview.project,
                environment: request.environment ?? preview.environment,
                variableNames: request.name.map { [$0] } ?? ["(changes the vault)"], callerPath: peer.path,
                callerChain: peer.ancestors.map { ($0.path as NSString).lastPathComponent }.joined(separator: " ← "),
                callerSigned: "Signature: \(peer.signingIdentifier ?? "unsigned")", allowsGrant: false))
            guard decision != .deny, await approvals.confirmWithOwner(reason: "let \(agent) change your vault (\(Self.short(action)))") else {
                logActivity(peer: peer, agent: agent, command: action, request: request, names: request.name.map { [$0] } ?? [], outcome: .denied)
                return .failure("The user denied this change.")
            }
            logActivity(peer: peer, agent: agent, command: action, request: request, names: request.name.map { [$0] } ?? [], outcome: .approved)
        }

        switch request.op {
        case .list: return list(request)
        case .activity:
            var response = BrokerResponse(ok: true)
            response.activity = Array(vault.data.activity.prefix(50))
            return response
        case .set: return set(request)
        case .remove: return remove(request)
        case .initProject: return initProject(request)
        case .importFolder: return importFolder(request)
        default: return .failure("Unsupported request.")
        }
    }

    static let noVaultMessage = "No vault yet. Open Redact.app to create one."

    // MARK: - Status and listing

    private func status(_ request: BrokerRequest) -> BrokerResponse {
        var response = BrokerResponse(ok: true)
        response.vaultExists = vault.state != .noVault
        response.locked = vault.state != .unlocked
        if vault.state == .unlocked, let project = vault.data.project(containing: request.cwd) {
            response.project = project.name
            response.projectPath = project.path
            response.environments = project.environments
            response.environment = request.environment ?? project.defaultEnvironment
        }
        let resolution = activeIdentity(for: request.cwd)
        response.activeIdentity = resolution.name
        response.activeIdentitySource = resolution.source
        return response
    }

    private func list(_ request: BrokerRequest) -> BrokerResponse {
        guard let project = vault.data.project(containing: request.cwd) else { return .failure(Self.noProject(request.cwd)) }
        let environments = request.environment.map { [$0] } ?? project.environments
        var response = BrokerResponse(ok: true)
        response.project = project.name
        response.projectPath = project.path
        response.environments = project.environments
        response.variables = environments.flatMap { env in
            vault.data.variables(projectID: project.id, environment: env).map { item in
                VariableInfo(name: item.name, environment: env,
                             linkedTo: item.linkedItemID.flatMap { id in vault.data.items.first { $0.id == id }?.name },
                             updatedAt: item.updatedAt)
            }
        }
        return response
    }

    static func noProject(_ cwd: String) -> String {
        "No Redact project contains \(cwd). Run `redact init` there, or drop the folder on Redact."
    }

    // MARK: - Resolve (the sensitive one)

    private func resolve(_ request: BrokerRequest, peer: PeerIdentity, agent: String?) async -> BrokerResponse {
        let commandText = (request.command ?? []).joined(separator: " ")

        // Agents get a decision panel before anything else (even before unlocking).
        var decision: ApprovalDecision = .once
        var approvedByUnlock = false
        var usedGrant = false
        if let agent {
            let preview = previewForApproval(request)
            if !(vault.state == .unlocked && approvals.hasGrant(agent: agent, projectPath: preview.projectPath, environment: preview.environment)) {
                decision = await approvals.ask(ApprovalRequest(
                    agent: agent, command: commandText.isEmpty ? "(no command)" : commandText,
                    directory: request.cwd, project: preview.project, environment: preview.environment,
                    variableNames: preview.names, callerPath: peer.path,
                    callerChain: peer.ancestors.map { ($0.path as NSString).lastPathComponent }.joined(separator: " ← "),
                    callerSigned: "Signature: \(peer.signingIdentifier ?? "unsigned")\(peer.teamIdentifier.map { " · team \($0)" } ?? "")"))
                if decision == .deny {
                    logActivity(peer: peer, agent: agent, command: commandText, request: request, names: preview.names, outcome: .denied)
                    return .failure("The user denied this request.")
                }
                if vault.state == .locked {
                    approvedByUnlock = true
                } else if !(await approvals.confirmWithOwner(reason: "let \(agent) run \(Self.short(commandText))")) {
                    logActivity(peer: peer, agent: agent, command: commandText, request: request, names: preview.names, outcome: .denied)
                    return .failure("Approval was cancelled.")
                }
            } else {
                decision = .once // existing grant; nothing to add
                usedGrant = true
            }
        }

        if vault.state == .locked {
            let reason = agent.map { "let \($0) run \(Self.short(commandText))" } ?? "unlock Redact to run \(Self.short(commandText))"
            guard await vault.unlock(reason: reason) else {
                if approvedByUnlock, let agent {
                    logActivity(peer: peer, agent: agent, command: commandText, request: request, names: [], outcome: .denied)
                }
                return .failure(vault.lastError ?? "Vault is locked.")
            }
        }
        vault.touch()

        var values: [String: String] = [:]
        var response = BrokerResponse(ok: true)
        var warnings: [String] = []
        let project = vault.data.project(containing: request.cwd)
        let environment = request.environment ?? project?.defaultEnvironment ?? "development"
        if let project {
            guard project.environments.contains(environment) else {
                return .failure("Project \(project.name) has no environment \"\(environment)\". It has: \(project.environments.joined(separator: ", ")).")
            }
            values = vault.data.environment(projectID: project.id, environment: environment)
            response.project = project.name
            response.projectPath = project.path
        }

        // Cloud identity in API-token mode: inject credentials for this folder.
        if let (identity, _) = vault.data.tokenIdentity(for: request.cwd),
           case let .apiToken(itemID, accountID) = identity.mode,
           let token = vault.data.items.first(where: { $0.id == itemID }) {
            values["CLOUDFLARE_API_TOKEN"] = token.value
            if let accountID, !accountID.isEmpty { values["CLOUDFLARE_ACCOUNT_ID"] = accountID }
        }

        if project == nil && values.isEmpty { return .failure(Self.noProject(request.cwd)) }

        if let agent, decision == .fifteenMinutes, let project {
            approvals.addGrant(agent: agent, projectPath: project.path, environment: environment, minutes: 15)
        }
        let names = values.keys.sorted()
        logActivity(peer: peer, agent: agent, command: commandText, request: request, names: names,
                    outcome: agent == nil ? .autoApproved : (usedGrant ? .granted : .approved))

        let redactor = Redactor(secrets: values)
        if !redactor.skipped.isEmpty {
            warnings.append("Not masked in output (shorter than \(Redactor.minimumSecretLength) characters): \(redactor.skipped.sorted().joined(separator: ", "))")
        }
        response.environment = environment
        response.values = values
        response.unmaskable = redactor.skipped.sorted()
        response.warnings = warnings.isEmpty ? nil : warnings
        return response
    }

    /// Names and project shown in the approval panel. Works while locked (shows what we can).
    private func previewForApproval(_ request: BrokerRequest) -> (project: String, projectPath: String, environment: String, names: [String]) {
        guard vault.state == .unlocked, let project = vault.data.project(containing: request.cwd) else {
            return ((request.cwd as NSString).lastPathComponent, request.cwd, request.environment ?? "default",
                    vault.state == .unlocked ? [] : ["(vault is locked: names shown after unlock)"])
        }
        let environment = request.environment ?? project.defaultEnvironment
        return (project.name, project.path, environment,
                vault.data.variables(projectID: project.id, environment: environment).map(\.name))
    }

    static func short(_ command: String) -> String {
        command.count > 60 ? String(command.prefix(57)) + "…" : (command.isEmpty ? "a command" : command)
    }

    private func logActivity(peer: PeerIdentity, agent: String?, command: String, request: BrokerRequest,
                             names: [String], outcome: ActivityEntry.Outcome) {
        guard vault.state == .unlocked else { return }
        vault.update {
            $0.log(ActivityEntry(caller: (peer.path as NSString).lastPathComponent, agent: agent,
                                 command: command, directory: request.cwd, variableNames: names, outcome: outcome))
        }
    }

    // MARK: - Changes

    private func set(_ request: BrokerRequest) -> BrokerResponse {
        guard let project = vault.data.project(containing: request.cwd) else { return .failure(Self.noProject(request.cwd)) }
        guard let name = request.name, EnvFile.isValidName(name) else { return .failure("Invalid variable name.") }
        guard let value = request.value else { return .failure("No value given.") }
        let environment = request.environment ?? project.defaultEnvironment
        guard project.environments.contains(environment) else { return .failure("Unknown environment \(environment).") }
        var created = true
        vault.update { data in
            if let index = data.items.firstIndex(where: { $0.kind == .variable && $0.projectID == project.id && $0.environment == environment && $0.name == name }) {
                data.items[index].value = value
                data.items[index].linkedItemID = nil
                data.items[index].updatedAt = Date()
                created = false
            } else {
                data.items.append(Item(kind: .variable, name: name, value: value, projectID: project.id, environment: environment))
            }
        }
        var response = BrokerResponse(ok: true)
        response.message = "\(created ? "Added" : "Updated") \(name) in \(project.name) · \(environment)."
        return response
    }

    private func remove(_ request: BrokerRequest) -> BrokerResponse {
        guard let project = vault.data.project(containing: request.cwd) else { return .failure(Self.noProject(request.cwd)) }
        guard let name = request.name else { return .failure("No variable name.") }
        let environment = request.environment ?? project.defaultEnvironment
        var removed = false
        vault.update { data in
            let before = data.items.count
            data.items.removeAll { $0.kind == .variable && $0.projectID == project.id && $0.environment == environment && $0.name == name }
            removed = data.items.count != before
        }
        guard removed else { return .failure("\(name) is not set in \(project.name) · \(environment).") }
        var response = BrokerResponse(ok: true)
        response.message = "Removed \(name) from \(project.name) · \(environment)."
        return response
    }

    private func initProject(_ request: BrokerRequest) -> BrokerResponse {
        let path = WranglerProfiles.realPath(request.path ?? request.cwd)
        if let existing = vault.data.projects.first(where: { $0.path == path }) {
            var response = BrokerResponse(ok: true)
            response.message = "\(existing.name) is already a Redact project."
            response.project = existing.name
            return response
        }
        let name = request.name ?? (path as NSString).lastPathComponent
        vault.update { $0.projects.append(Project(name: name, path: path)) }
        var response = BrokerResponse(ok: true)
        response.project = name
        response.projectPath = path
        response.message = "Created project \(name) (\(Project.defaultEnvironments.joined(separator: ", ")))."
        return response
    }

    /// CLI import: everything new or changed in the folder's env files, linking duplicates.
    private func importFolder(_ request: BrokerRequest) -> BrokerResponse {
        let root = WranglerProfiles.realPath(request.path ?? request.cwd)
        if vault.data.project(containing: root) == nil {
            _ = initProject(BrokerRequest(op: .initProject, cwd: root))
        }
        guard let project = vault.data.project(containing: root) else { return .failure(Self.noProject(root)) }
        do {
            var plan = try ImportPlan.build(root: root, project: project, vault: vault.data)
            if let environment = request.environment {
                plan.rows = plan.rows.map { var row = $0; row.environment = environment; return row }
            }
            var touched: [UUID] = []
            vault.update { data in
                for environment in Set(plan.rows.map(\.environment)) where !data.projects.contains(where: { $0.id == project.id && $0.environments.contains(environment) }) {
                    if let index = data.projects.firstIndex(where: { $0.id == project.id }) { data.projects[index].environments.append(environment) }
                }
                touched = plan.apply(to: &data, project: project)
            }
            var response = BrokerResponse(ok: true)
            let unchanged = plan.rows.filter { $0.status == .unchanged }.count
            let linked = plan.rows.filter { $0.selected && $0.duplicateOf != nil }.count
            response.message = "Imported \(touched.count) variables into \(project.name) from \(plan.files.filter { !$0.isExample }.count) files (\(unchanged) unchanged, \(linked) linked to existing keys)."
            var warnings = plan.missingFromExample.sorted { $0.key < $1.key }.map { "\($0.key): missing \($0.value.joined(separator: ", ")) (listed in .env.example)" }
            let files = plan.files.filter { !$0.isExample }.map(\.relativePath)
            if !files.isEmpty {
                warnings.append("Plaintext files still on disk: \(files.joined(separator: ", ")). Delete them once `redact run` works for you.")
            }
            response.warnings = warnings
            return response
        } catch {
            return .failure("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Identities

    private func activeIdentity(for cwd: String) -> (name: String?, source: String?) {
        if vault.state == .unlocked, let (identity, path) = vault.data.tokenIdentity(for: cwd) {
            return (identity.name, "Redact API token, bound at \(path)")
        }
        let resolved = WranglerProfiles(configRoot: WranglerProfiles.defaultConfigRoot()).resolve(directory: cwd)
        return ("wrangler:\(resolved.profile)", resolved.source)
    }

    private func identities(_ request: BrokerRequest) -> BrokerResponse {
        let store = WranglerProfiles(configRoot: WranglerProfiles.defaultConfigRoot())
        let bindings = store.bindings()
        var list = store.profiles().map { profile in
            IdentityInfo(name: profile.name, provider: "cloudflare", mode: "wrangler-profile",
                         boundPaths: bindings.filter { $0.value == profile.name }.map(\.key).sorted(),
                         encrypted: profile.encrypted)
        }
        if vault.state == .unlocked {
            list += vault.data.identities.compactMap { identity in
                guard case .apiToken = identity.mode else { return nil }
                return IdentityInfo(name: identity.name, provider: identity.provider.rawValue, mode: "api-token",
                                    boundPaths: identity.boundPaths, encrypted: true)
            }
        }
        var response = status(request)
        response.identities = list
        var warnings: [String] = []
        let broken = store.brokenBindings()
        if !broken.isEmpty { warnings.append("These Wrangler bindings never apply because the path is a symlink: \(broken.joined(separator: ", ")). Re-bind with `redact id bind`.") }
        if list.contains(where: { $0.mode == "wrangler-profile" && $0.encrypted == false }) {
            warnings.append("Some Wrangler logins are stored in plaintext. Run `wrangler auth keyring enable` to move them to the Keychain.")
        }
        if ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"] != nil {
            warnings.append("CLOUDFLARE_API_TOKEN is set in Redact's environment; it overrides every profile.")
        }
        response.warnings = warnings.isEmpty ? nil : warnings
        return response
    }

    private func bindIdentity(_ request: BrokerRequest) async -> BrokerResponse {
        guard let name = request.name else { return .failure("Which identity?") }
        let directory = WranglerProfiles.realPath(request.path ?? request.cwd)
        if vault.state == .unlocked, let index = vault.data.identities.firstIndex(where: { $0.name == name }) {
            vault.update { data in
                for i in data.identities.indices { data.identities[i].boundPaths.removeAll { $0 == directory } }
                data.identities[index].boundPaths.append(directory)
            }
            var response = BrokerResponse(ok: true)
            response.message = "Bound \(name) (API token) to \(directory)."
            return response
        }
        let store = WranglerProfiles(configRoot: WranglerProfiles.defaultConfigRoot())
        guard store.profiles().contains(where: { $0.name == name }) else {
            return .failure("No Wrangler profile or Redact identity called \(name). Create it with `wrangler auth create \(name)` or in Redact → Identities.")
        }
        if name == "default" {
            let result = await WranglerCLI.deactivate(directory: directory)
            return result.status == 0 ? BrokerResponse(ok: true) : .failure(result.output)
        }
        let result = await WranglerCLI.activate(profile: name, directory: directory)
        guard result.status == 0 else { return .failure(result.output.isEmpty ? "wrangler auth activate failed." : result.output) }
        var response = BrokerResponse(ok: true)
        response.message = "Bound Wrangler profile \(name) to \(directory)."
        return response
    }
}
