import Foundation
import RedactCore

/// Answers requests from the `redact` CLI and `redact mcp`.
@MainActor
final class BrokerHandler {
    let vault: VaultController
    let approvals: ApprovalCenter
    let llmProxy: LLMProxy

    init(vault: VaultController, approvals: ApprovalCenter, llmProxy: LLMProxy) {
        self.vault = vault
        self.approvals = approvals
        self.llmProxy = llmProxy
    }

    /// The `redact` CLI inside this app bundle, pinned by its code directory hash.
    static let bundledCLIHash: Data? = PeerIdentity.cdhash(ofFile: Bundle.main.bundlePath + "/Contents/Resources/bin/redact")

    /// Whether the peer is exactly the `redact` binary this app ships (not a script talking to the socket).
    static func isGenuineCLI(_ peer: PeerIdentity) -> Bool {
        guard let expected = bundledCLIHash, peer.signatureValid, let hash = peer.cdhash else { return false }
        return hash == expected
    }

    /// Who to show in approvals, or nil when it is plainly the user: the genuine CLI, started from a
    /// terminal app, with no AI agent above it. Everything else (agents, scripts, detached or
    /// background processes) is asked about, with Touch ID.
    static func caller(_ peer: PeerIdentity, viaMCP: Bool) -> String? {
        if viaMCP { return peer.agentGuess ?? "An MCP agent" }
        if let agent = peer.agentGuess { return agent }
        if isGenuineCLI(peer) && peer.launchedFromTerminal { return nil }
        let name = (peer.path as NSString).lastPathComponent
        return isGenuineCLI(peer) ? "redact, not started from a terminal" : "\(name.isEmpty ? "An unknown program" : name)"
    }

    func handle(_ request: BrokerRequest, peer: PeerIdentity) async -> BrokerResponse {
        var request = request
        let caller = Self.caller(peer, viaMCP: request.viaMCP == true)
        if let name = request.project {
            switch Self.projectFolder(named: name, in: vault.state == .unlocked ? vault.data.projects : vault.projectIndex) {
            case .success(let path): request.cwd = path
            case .failure(let message): return .failure(message.text)
            }
        }
        switch request.op {
        case .status: return status(request)
        case .lock:
            vault.lock()
            return BrokerResponse(ok: true)
        case .unlock:
            guard vault.state != .noVault else { return .failure(Self.noVaultMessage) }
            let reason = caller.map { "let \($0) unlock your Redact vault" } ?? "unlock your Redact vault"
            return await vault.unlock(reason: reason) ? status(request) : .failure(vault.lastError ?? "Unlock failed.")
        case .endProxy:
            llmProxy.endSessions(request.proxySessions ?? [])
            return BrokerResponse(ok: true)
        case .identities:
            if vault.state == .locked { _ = await vault.unlock(reason: "list your accounts") }
            return identities(request)
        case .bindIdentity:
            // Rebinding could send an agent's deploys to another account: needs the user's approval.
            if let agent = caller {
                if request.viaMCP == true { return .failure("Agents can't change identity bindings.") }
                let action = "redact id bind \(request.name ?? "") \(request.path ?? request.cwd)"
                let decision = await approvals.ask(ApprovalRequest(
                    agent: agent, command: action, directory: request.cwd, project: (request.cwd as NSString).lastPathComponent,
                    environment: "cloud identity", variableNames: ["(changes which Cloudflare account this folder uses)"],
                    callerPath: peer.path,
                    callerChain: peer.ancestors.map { ($0.path as NSString).lastPathComponent }.joined(separator: " ← "),
                    callerSigned: "Signature: \(peer.signingIdentifier ?? "unsigned")", allowsGrant: false))
                guard decision != .deny, await approvals.confirmWithOwner(reason: "let \(agent) change a Cloudflare binding") else {
                    return .failure("The user denied this change.")
                }
            }
            return await bindIdentity(request)
        case .scan where request.scan?.text != nil && vault.state != .unlocked:
            // Pre-commit: never prompt. The CLI falls back to format-only scanning.
            var response = BrokerResponse(ok: true)
            response.locked = true
            return response
        default: break
        }

        // Everything below needs the vault open.
        guard vault.state != .noVault else { return .failure(Self.noVaultMessage) }
        let agent = caller

        if request.op == .resolve {
            // Values only ever go to the redact CLI, which runs the command it showed in the approval.
            // A script on the socket could show "npm test" and keep the values for itself.
            guard Self.isGenuineCLI(peer) else {
                return .failure("Only the redact command can receive secret values. Use `redact run -- CMD`.")
            }
            return await resolve(request, peer: peer, agent: agent)
        }
        if vault.state == .locked {
            let reason = agent.map { "let \($0) use Redact" } ?? "unlock your Redact vault"
            guard await vault.unlock(reason: reason) else { return .failure(vault.lastError ?? "Vault is locked.") }
        }
        vault.touch()

        // Agents must not change the vault on their own: they could replace a key with one they control.
        if let agent, [.set, .remove, .importFolder, .initProject, .addIdentity].contains(request.op) {
            if request.viaMCP == true { return .failure("Agents can't change the vault. Ask the user to do it in Redact.") }
            let action: String
            switch request.op {
            case .set: action = "redact set \(request.name ?? "")\(request.environment.map { " --env \($0)" } ?? "")"
            case .remove: action = "redact rm \(request.name ?? "")\(request.environment.map { " --env \($0)" } ?? "")"
            case .importFolder: action = "redact import \(request.path ?? request.cwd)"
            case .addIdentity: action = "redact id add \(request.provider ?? "") \(request.name ?? "")"
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
        case .scan:
            guard let options = request.scan else { return .failure("Nothing to scan.") }
            var secrets = Self.scanSecrets(vault.data)
            // Anyone but the user could use scan as an oracle: "does this guess match a vault value?".
            // For them, only look for long values, which can't be guessed.
            if agent != nil { secrets = secrets.filter { $0.value.count >= 20 } }
            let findings = await Task.detached { HealthScan.run(options, secrets: secrets) }.value
            var response = BrokerResponse(ok: true)
            response.findings = findings
            return response
        case .set: return set(request)
        case .remove: return remove(request)
        case .addIdentity: return addIdentity(request)
        case .initProject: return initProject(request)
        case .importFolder: return importFolder(request)
        default: return .failure("Unsupported request.")
        }
    }

    static let noVaultMessage = "No vault yet. Open Redact.app to create one."

    /// Values to look for when scanning, labelled so findings say exactly which secret leaked.
    static func scanSecrets(_ data: VaultData) -> [String: String] {
        var secrets: [String: String] = [:]
        for item in data.items {
            switch item.kind {
            case .apiKey, .note:
                guard SecretScanner.isSecretLike(name: item.name, value: item.value) else { continue }
                secrets[item.name] = item.value
            case .variable:
                guard item.linkedItemID == nil else { continue } // the shared key is scanned under its own name
                guard SecretScanner.isSecretLike(name: item.name, value: item.value) else { continue }
                let project = data.projects.first { $0.id == item.projectID }?.name ?? "?"
                secrets["\(item.name) (\(project) · \(item.environment ?? ""))"] = item.value
            case .backupCodes:
                continue
            }
        }
        return secrets
    }

    // MARK: - Status and listing

    private func status(_ request: BrokerRequest) -> BrokerResponse {
        var response = BrokerResponse(ok: true)
        response.vaultExists = vault.state != .noVault
        response.locked = vault.state != .unlocked
        var index = VaultData()
        index.projects = vault.state == .unlocked ? vault.data.projects : vault.projectIndex
        index.identities = vault.state == .unlocked ? vault.data.identities : vault.identityIndex
        let bound = index.boundIdentities(for: request.cwd)
        let active = bound.sorted { $0.key.rawValue < $1.key.rawValue }
            .filter { $0.key != .cloudflare }
            .map { "\($0.key.rawValue): \($0.value.0.name)" }
        response.activeIdentities = active.isEmpty ? nil : active
        if let (aws, _) = bound[.aws], case let .awsProfile(name) = aws.mode { response.awsProfile = name }
        if let project = index.project(containing: request.cwd) {
            response.project = project.name
            response.projectPath = project.path
            response.environments = project.environments
            response.environment = request.environment ?? project.defaultEnvironment
        }
        let resolution = activeIdentity(for: request.cwd)
        response.activeIdentity = resolution.name
        response.activeIdentitySource = resolution.source
        if let pin = WranglerConfig.pinnedAccount(from: request.cwd) {
            response.pinnedAccount = pin.accountID
            response.pinnedAccountFile = pin.file
            if let advice = identityAdvice(cwd: request.cwd, pin: pin) { response.warnings = [advice] }
        }
        return response
    }

    /// CF-4: compares the folder's pinned account with the identity that applies there.
    private func identityAdvice(cwd: String, pin: WranglerConfig.Pin) -> String? {
        guard vault.state == .unlocked else { return nil }
        let file = (pin.file as NSString).lastPathComponent
        func account(_ identity: Identity) -> String? {
            if case let .apiToken(_, accountID) = identity.mode { return accountID }
            return nil
        }
        if let (identity, _) = vault.data.tokenIdentity(for: cwd) {
            if let id = account(identity), id != pin.accountID {
                return "\(file) pins account \(pin.accountID), but identity \(identity.name) is for account \(id). Deploys will fail or go to the wrong account."
            }
            return nil
        }
        if let match = vault.data.identities.first(where: { account($0) == pin.accountID }) {
            return "\(file) pins account \(pin.accountID), which matches identity \(match.name). Bind it here with `redact id bind \(match.name)`."
        }
        return nil
    }

    private func list(_ request: BrokerRequest) -> BrokerResponse {
        guard let project = vault.data.project(containing: request.cwd) else { return .failure(noProject(request.cwd)) }
        let environments = request.environment.map { [$0] } ?? project.environments
        var response = BrokerResponse(ok: true)
        response.project = project.name
        response.projectPath = project.path
        response.environments = project.environments
        response.environment = request.environment ?? project.defaultEnvironment
        response.variables = environments.flatMap { env in
            vault.data.variables(projectID: project.id, environment: env).map { item in
                VariableInfo(name: item.name, environment: env,
                             linkedTo: item.linkedItemID.flatMap { id in vault.data.items.first { $0.id == id }?.name },
                             updatedAt: item.updatedAt)
            }
        }
        return response
    }

    func noProject(_ cwd: String) -> String {
        Self.noProject(cwd, projects: vault.state == .unlocked ? vault.data.projects : vault.projectIndex)
    }

    /// Explains a folder with no project. A monorepo root gets the projects inside it and how to pick one.
    static func noProject(_ cwd: String, projects: [Project] = []) -> String {
        let root = WranglerProfiles.realPath(cwd)
        let inside = projects.filter { $0.path.hasPrefix(root + "/") }.sorted { $0.path < $1.path }
        guard let first = inside.first else {
            return "No Redact project contains \(cwd). Run `redact init` there, or drop the folder on Redact."
        }
        let list = inside.map { "\($0.name) (\(String($0.path.dropFirst(root.count + 1))))" }.joined(separator: ", ")
        return "\((cwd as NSString).lastPathComponent) has \(inside.count) project\(inside.count == 1 ? "" : "s") inside it: \(list). "
            + "Run inside one, or pick one by name: `redact run -p \(first.name) -- …`"
    }

    struct Message: Error { let text: String }

    /// The folder of the project called `name` (case-insensitive).
    static func projectFolder(named name: String, in projects: [Project]) -> Result<String, Message> {
        let matches = projects.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        switch matches.count {
        case 1: return .success(matches[0].path)
        case 0:
            let names = projects.map(\.name).sorted().joined(separator: ", ")
            return .failure(Message(text: "No project called \(name). Projects: \(names.isEmpty ? "none yet" : names)."))
        default:
            return .failure(Message(text: "\(matches.count) projects are called \(name): \(matches.map(\.path).joined(separator: ", ")). Run inside the one you mean."))
        }
    }

    // MARK: - Resolve (the sensitive one)

    private func resolve(_ request: BrokerRequest, peer: PeerIdentity, agent: String?) async -> BrokerResponse {
        let commandText = (request.command ?? []).joined(separator: " ")

        // Tool wrappers while locked: if no identity is bound here, pass through without a Touch ID prompt.
        if request.ifAny == true, request.identityOnly == true, vault.state == .locked {
            var index = VaultData()
            index.identities = vault.identityIndex
            if !vault.identityIndex.isEmpty, index.boundIdentities(for: request.cwd).isEmpty {
                var response = BrokerResponse(ok: true)
                response.values = [:]
                return response
            }
        }

        // Shell wrappers: nothing to inject here, so don't bother the user.
        if request.ifAny == true, vault.state == .unlocked,
           vault.data.project(containing: request.cwd) == nil || request.identityOnly == true,
           vault.data.boundIdentities(for: request.cwd).isEmpty {
            var response = BrokerResponse(ok: true)
            response.values = [:]
            return response
        }

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
        if let project, request.identityOnly != true {
            guard project.environments.contains(environment) else {
                return .failure("Project \(project.name) has no environment \"\(environment)\". It has: \(project.environments.joined(separator: ", ")).")
            }
            values = vault.data.environment(projectID: project.id, environment: environment)
            response.project = project.name
            response.projectPath = project.path
        }

        // Cloud identities bound to this folder (Cloudflare, GitHub, Vercel, Supabase, AWS).
        let identityEnv = vault.data.identityEnvironment(for: request.cwd)
        if !identityEnv.values.isEmpty {
            for (name, value) in identityEnv.values { values[name] = value }
            response.identityNames = identityEnv.values.keys.sorted()
            response.identityProviders = identityEnv.providers.mapValues(\.rawValue)
        }

        if (project == nil || request.identityOnly == true) && values.isEmpty {
            if request.ifAny == true {
                response.values = [:]
                return response
            }
            return .failure(noProject(request.cwd))
        }

        if let agent, decision == .fifteenMinutes, let project {
            approvals.addGrant(agent: agent, projectPath: project.path, environment: environment, minutes: 15)
        }
        // OpenAI / Anthropic keys: the command gets a placeholder and a local base URL, never the key.
        if agent != nil || request.llmProxy == true {
            var proxied: [String] = []
            var sessions: [String] = []
            for provider in LLMProxy.Provider.allCases {
                guard let key = values[provider.keyVariable], !key.isEmpty,
                      values[provider.baseURLVariable] == nil else { continue } // custom base URL (e.g. Azure): leave alone
                do {
                    let port = try llmProxy.start()
                    let placeholder = llmProxy.createSession(provider: provider, key: key, label: commandText)
                    values[provider.keyVariable] = placeholder
                    values[provider.baseURLVariable] = provider.baseURL(port: port)
                    proxied.append(provider.keyVariable)
                    sessions.append(placeholder)
                } catch {
                    warnings.append("LLM proxy unavailable (\(error.localizedDescription)); \(provider.keyVariable) not injected.")
                    values.removeValue(forKey: provider.keyVariable)
                }
            }
            if !proxied.isEmpty {
                response.proxiedNames = proxied
                response.proxySessions = sessions
            }
        }

        let names = values.keys.sorted().map { name in
            (response.proxiedNames ?? []).contains(name) ? "\(name) (via proxy)" : name
        }
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
        if request.identityOnly == true, vault.state == .unlocked {
            let names = vault.data.identityEnvironment(for: request.cwd).values.keys.sorted()
            let project = vault.data.project(containing: request.cwd)
            // Same environment key as the grant, so "Allow for 15 min" covers wrapper runs too.
            let environment = request.environment ?? project?.defaultEnvironment ?? "development"
            return (project?.name ?? (request.cwd as NSString).lastPathComponent, project?.path ?? request.cwd, environment, names)
        }
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
        guard let project = vault.data.project(containing: request.cwd) else { return .failure(noProject(request.cwd)) }
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
        guard let project = vault.data.project(containing: request.cwd) else { return .failure(noProject(request.cwd)) }
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
        guard let project = vault.data.project(containing: root) else { return .failure(noProject(root)) }
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

    private func addIdentity(_ request: BrokerRequest) -> BrokerResponse {
        guard let providerName = request.provider, let provider = Identity.Provider(rawValue: providerName.lowercased()) else {
            return .failure("Unknown provider. Use one of: \(Identity.Provider.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let name = request.name, !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return .failure("Identity names may contain letters, numbers, - and _.")
        }
        let wranglerNames = WranglerProfiles(configRoot: WranglerProfiles.defaultConfigRoot()).profiles().map(\.name)
        guard !vault.data.identities.contains(where: { $0.name == name }), !wranglerNames.contains(name) else {
            return .failure("An identity called \(name) already exists. Names must be unique so `redact id bind` is unambiguous.")
        }
        let identity: Identity
        var item: Item?
        if provider == .aws {
            guard let profile = request.scope, !profile.isEmpty else { return .failure("AWS identities need --profile NAME (from ~/.aws/config).") }
            identity = Identity(provider: .aws, name: name, mode: .awsProfile(name: profile))
        } else {
            guard let token = request.value?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                return .failure("No token given.")
            }
            let tokenItem = Item(kind: .apiKey, name: "\(provider.displayName) token · \(name)", value: token, tags: [provider.rawValue, "identity"])
            item = tokenItem
            identity = Identity(provider: provider, name: name, mode: .apiToken(itemID: tokenItem.id, accountID: request.scope))
        }
        vault.update { data in
            if let item { data.items.append(item) }
            data.identities.append(identity)
        }
        var response = BrokerResponse(ok: true)
        response.message = "Added \(provider.displayName) identity \(name). Bind it to a folder with `redact id bind \(name) [dir]`."
        return response
    }

    private func activeIdentity(for cwd: String) -> (name: String?, source: String?) {
        var index = VaultData()
        index.identities = vault.state == .unlocked ? vault.data.identities : vault.identityIndex
        if let (identity, path) = index.tokenIdentity(for: cwd) {
            return (identity.name, "Redact API token, bound at \(path)")
        }
        let resolved = WranglerProfiles(configRoot: WranglerProfiles.defaultConfigRoot()).resolve(directory: cwd)
        let caveat = vault.state == .unlocked || !vault.identityIndex.isEmpty ? "" : " (vault locked: Redact API-token identities not checked; run `redact unlock`)"
        return ("wrangler:\(resolved.profile)", resolved.source + caveat)
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
                switch identity.mode {
                case let .apiToken(_, scope):
                    return IdentityInfo(name: identity.name, provider: identity.provider.rawValue, mode: "api-token",
                                        boundPaths: identity.boundPaths, encrypted: true, scope: scope)
                case let .awsProfile(name):
                    return IdentityInfo(name: identity.name, provider: "aws", mode: "aws-profile",
                                        boundPaths: identity.boundPaths, encrypted: nil, scope: name)
                case .wranglerProfile:
                    return nil
                }
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
        let isWranglerProfile = WranglerProfiles(configRoot: WranglerProfiles.defaultConfigRoot()).profiles().contains { $0.name == name }
        if !isWranglerProfile, vault.state == .locked {
            guard await vault.unlock(reason: "bind \(name) to a folder") else { return .failure(vault.lastError ?? "Vault is locked.") }
        }
        if vault.state == .unlocked, let index = vault.data.identities.firstIndex(where: { $0.name == name }) {
            vault.update { data in
                for i in data.identities.indices { data.identities[i].boundPaths.removeAll { $0 == directory } }
                data.identities[index].boundPaths.append(directory)
            }
            var response = BrokerResponse(ok: true)
            let provider = vault.data.identities[index].provider.displayName
            response.message = "Bound \(provider) identity \(name) to \(directory)."
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
