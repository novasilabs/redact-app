import RedactCore
import SwiftUI

/// Cloud accounts and the folders they're bound to (PRD §6.8, CF-1…CF-5, CF-9, CF-10).
struct IdentitiesView: View {
    @EnvironmentObject var vault: VaultController
    @State private var profiles: [WranglerProfiles.Profile] = []
    @State private var bindings: [String: String] = [:]
    @State private var broken: [String] = []
    @State private var busy: String?
    @State private var output: String?
    @State private var newProfile = ""
    @State private var showTokenSheet = false
    @State private var whoami: [String: String] = [:]

    private var store: WranglerProfiles { WranglerProfiles(configRoot: WranglerProfiles.defaultConfigRoot()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                PageHeader(title: "Accounts",
                           subtitle: "Bind each account to the folders it owns. Inside a bound folder, plain `wrangler deploy`, `gh` or `vercel` use that account. No more logging out and back in.") {
                    Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.secondary)
                    Button { showTokenSheet = true } label: { Label("Add account", systemImage: "plus") }.buttonStyle(.primary)
                }

                warnings

                if let busy {
                    HStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(TextStyle.small).foregroundStyle(Palette.ink2)
                    }
                }
                if let output {
                    VStack(alignment: .leading, spacing: Space.s) {
                        GroupLabel(title: "Wrangler output") {
                            Button("Clear") { self.output = nil }.buttonStyle(.quiet)
                        }
                        Text(output)
                            .font(TextStyle.monoSmall)
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .padding(Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sunken(radius: Radius.card)
                    }
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    GroupLabel(title: "Cloudflare: Wrangler profiles") {
                        Text("Logins live in Wrangler, Redact only binds folders").font(TextStyle.caption).foregroundStyle(Palette.ink2)
                    }
                    VStack(spacing: 0) {
                        if profiles.count > 1 {
                            fallbackRow
                            Rule()
                        }
                        ForEach(Array(profiles.enumerated()), id: \.element.name) { index, profile in
                            if index > 0 { Rule(inset: 52) }
                            profileRow(profile)
                        }
                        if !profiles.isEmpty { Rule() }
                        HStack(spacing: Space.s) {
                            Field(placeholder: "New profile name, e.g. acme", text: $newProfile, mono: true)
                                .frame(width: 260)
                                .onSubmit(createProfile)
                            Button("Log in and create", action: createProfile)
                                .buttonStyle(.secondary)
                                .disabled(!isValidProfileName(newProfile) || busy != nil)
                            Text("Opens Cloudflare in your browser").font(TextStyle.small).foregroundStyle(Palette.ink2)
                            Spacer(minLength: 0)
                        }
                        .padding(Space.m)
                    }
                    .card()
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    GroupLabel(title: "Tokens and profiles in this vault") {
                        Text("Set for bound folders by `redact run` and the shell hook").font(TextStyle.caption).foregroundStyle(Palette.ink2)
                    }
                    let tokenIdentities = Identity.Provider.allCases.flatMap { provider in vault.data.identities.filter { $0.provider == provider } }
                    VStack(spacing: 0) {
                        ForEach(Array(tokenIdentities.enumerated()), id: \.element.id) { index, identity in
                            if index > 0 { Rule(inset: 52) }
                            tokenRow(identity)
                        }
                        if tokenIdentities.isEmpty {
                            EmptyState(symbol: "person.2", title: "No accounts yet",
                                       message: "Add a GitHub, Vercel, Supabase or Cloudflare token, or pick an AWS profile. Redact sets it only inside the folders you bind.") {
                                Button { showTokenSheet = true } label: { Label("Add account", systemImage: "plus") }.buttonStyle(.secondary)
                            }
                        }
                    }
                    .card()
                }

            }
            .padding(Space.xl)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showTokenSheet) { TokenIdentitySheet() }
    }

    @ViewBuilder private var warnings: some View {
        if profiles.contains(where: { !$0.encrypted }) {
            Notice(symbol: "exclamationmark.triangle.fill", text: "Some Wrangler logins are stored as plaintext files.") {
                Button("Move to Keychain") {
                    let plaintext = profiles.filter { !$0.encrypted }.map(\.name)
                    runWrangler("Moving logins to the Keychain…") { await WranglerCLI.moveTokensToKeychain(profiles: plaintext) }
                }
                .disabled(busy != nil)
                    .buttonStyle(.secondary)
            }
        }
        if !broken.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Notice(symbol: "exclamationmark.triangle.fill",
                       text: "These bindings never apply: the path is a symlink and Wrangler looks up the real path.")
                ForEach(broken, id: \.self) { path in
                    HStack {
                        PathLabel(path: path)
                        Spacer()
                        Button("Fix") { fixBinding(path) }.buttonStyle(.secondary)
                    }
                    .padding(.horizontal, Space.m)
                }
            }
        }
    }

    /// The home folder as Wrangler stores it. A binding here is the fallback for every unbound folder
    /// under it, because Wrangler picks the longest bound prefix.
    private var homePath: String { WranglerProfiles.realPath(NSHomeDirectory()) }

    /// The profile unbound folders deploy with: whatever is bound to the home folder, else `default`.
    private var fallbackProfile: String { bindings[homePath] ?? "default" }

    private var fallbackRow: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink2).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Default account").font(TextStyle.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text("Used in folders you haven't bound")
                    .font(TextStyle.small).foregroundStyle(Palette.ink2)
            }
            Spacer()
            Picker("Default account", selection: Binding(get: { fallbackProfile }, set: setFallback)) {
                ForEach(profiles, id: \.name) { profile in
                    Text(profile.name == "default" ? "default login" : profile.name).tag(profile.name)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(busy != nil)
        }
        .padding(Space.m)
    }

    private func setFallback(_ profile: String) {
        guard profile != fallbackProfile else { return }
        let home = homePath
        if profile == "default" {
            runWrangler("Unbound folders now use the default login…") { await WranglerCLI.deactivate(directory: home) }
        } else {
            runWrangler("Unbound folders now use \(profile)…") { await WranglerCLI.activate(profile: profile, directory: home) }
        }
    }

    private func profileRow(_ profile: WranglerProfiles.Profile) -> some View {
        let paths = bindings.filter { $0.value == profile.name && $0.key != homePath }.map(\.key).sorted()
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                BrandTile(brand: .named("Cloudflare"), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s) {
                        Text(profile.name).font(TextStyle.monoStrong).foregroundStyle(Palette.ink)
                        if profile.encrypted {
                            Pill(text: "Keychain", symbol: "lock.fill")
                        } else {
                            Pill(text: "Plaintext file", symbol: "lock.open.fill", tone: .warning)
                        }
                    }
                    Text(profile.name == "default"
                         ? (fallbackProfile == "default" ? "Used in folders you haven't bound" : "Used only outside your home folder")
                         : (whoami[profile.name] ?? "\(paths.count) folder\(paths.count == 1 ? "" : "s")"))
                        .font(TextStyle.small).foregroundStyle(Palette.ink2)
                }
                Spacer()
                if profile.name != "default" {
                    Button("Bind folder…") { bind(profile.name) }.buttonStyle(.secondary)
                    Menu {
                        if let first = paths.first { Button("Check account") { check(profile.name, in: first) } }
                        Button("Re-authenticate") { runWrangler("Re-authenticating \(profile.name)…") { await WranglerCLI.createProfile(profile.name) } }
                        Divider()
                        Button("Delete profile", role: .destructive) {
                            runWrangler("Deleting \(profile.name)…") { await WranglerCLI.run(["auth", "delete", profile.name]) }
                        }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(Palette.ink2).frame(width: 24, height: 24) }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                }
            }
            ForEach(paths, id: \.self) { path in
                BoundFolderRow(path: path) {
                    runWrangler("Unbinding…") { await WranglerCLI.deactivate(directory: path) }
                }
            }
        }
        .padding(Space.m)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard profile.name != "default", let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath else { return }
                Task { @MainActor in
                    runWrangler("Binding \(profile.name)…") { await WranglerCLI.activate(profile: profile.name, directory: url.path) }
                }
            }
            return true
        }
    }

    private func tokenRow(_ identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                BrandTile(brand: .of(identity.provider), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.name).font(TextStyle.monoStrong).foregroundStyle(Palette.ink)
                    Group {
                        switch identity.mode {
                        case let .apiToken(_, accountID):
                            if let accountID {
                                Text("\(identity.provider.displayName) token, \(identity.provider.scopeLabel?.lowercased() ?? "scope") ")
                                    + Text(accountID).font(TextStyle.monoSmall)
                            } else {
                                Text("\(identity.provider.displayName) token")
                            }
                        case let .awsProfile(name):
                            Text("AWS profile ") + Text(name).font(TextStyle.monoSmall)
                        case .wranglerProfile:
                            Text("Wrangler profile")
                        }
                    }
                    .font(TextStyle.small)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer()
                Button("Bind folder…") { bindToken(identity) }.buttonStyle(.secondary)
                IconButton(symbol: "trash", help: "Remove account", tint: Palette.danger) { removeIdentity(identity) }
            }
            ForEach(identity.boundPaths, id: \.self) { path in
                BoundFolderRow(path: path) {
                    vault.update { data in
                        if let i = data.identities.firstIndex(where: { $0.id == identity.id }) { data.identities[i].boundPaths.removeAll { $0 == path } }
                    }
                }
            }
            if identity.boundPaths.isEmpty {
                Text("Not bound to any folder yet").font(TextStyle.small).foregroundStyle(Palette.ink2).padding(.leading, 40)
            }
        }
        .padding(Space.m)
    }

    private func removeIdentity(_ identity: Identity) {
        let alert = NSAlert()
        alert.messageText = "Remove the \(identity.provider.displayName) account \(identity.name)?"
        alert.informativeText = identity.tokenItemID == nil
            ? "Its folder bindings are removed. Your AWS profile isn't touched."
            : "Its token is deleted from the vault and its folder bindings are removed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        vault.update { data in
            if case let .apiToken(itemID, _) = identity.mode { data.items.removeAll { $0.id == itemID } }
            data.identities.removeAll { $0.id == identity.id }
        }
    }

    static func icon(_ provider: Identity.Provider) -> String {
        switch provider {
        case .cloudflare: "cloud"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .vercel: "triangle"
        case .supabase: "cylinder"
        case .aws: "server.rack"
        }
    }

    // MARK: - Actions

    private func reload() {
        let store = self.store
        profiles = store.profiles()
        bindings = store.bindings()
        broken = store.brokenBindings()
    }

    private func isValidProfileName(_ name: String) -> Bool {
        !name.isEmpty && name.lowercased() != "default" && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func createProfile() {
        let name = newProfile
        runWrangler("Waiting for you to log in to Cloudflare in your browser…") { await WranglerCLI.createProfile(name) }
        newProfile = ""
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Bind"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func bind(_ profile: String) {
        guard let path = chooseFolder() else { return }
        runWrangler("Binding \(profile)…") { await WranglerCLI.activate(profile: profile, directory: path) }
    }

    private func bindToken(_ identity: Identity) {
        guard let path = chooseFolder() else { return }
        let real = WranglerProfiles.realPath(path)
        vault.update { data in
            for i in data.identities.indices { data.identities[i].boundPaths.removeAll { $0 == real } }
            if let i = data.identities.firstIndex(where: { $0.id == identity.id }) { data.identities[i].boundPaths.append(real) }
        }
    }

    private func fixBinding(_ path: String) {
        guard let profile = bindings[path] else { return }
        runWrangler("Re-binding \(profile) at the real path…") {
            _ = await WranglerCLI.deactivate(directory: path)
            return await WranglerCLI.activate(profile: profile, directory: path)
        }
    }

    private func check(_ profile: String, in directory: String) {
        busy = "Asking Cloudflare who \(profile) is…"
        Task {
            let result = await WranglerCLI.whoami(in: directory)
            busy = nil
            if result.status == 0, let json = result.output.firstIndex(of: "{").map({ String(result.output[$0...]) }),
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                let email = object["email"] as? String ?? "?"
                let accounts = (object["accounts"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                whoami[profile] = "\(email) · \(accounts.joined(separator: ", "))"
            } else {
                output = result.output
            }
        }
    }

    private func runWrangler(_ message: String, _ work: @escaping () async -> WranglerCLI.Result) {
        busy = message
        output = nil
        Task {
            let result = await work()
            busy = nil
            output = result.output.isEmpty ? (result.status == 0 ? "Done." : "Failed (exit \(result.status)).") : result.output
            reload()
        }
    }
}

struct TokenIdentitySheet: View {
    @EnvironmentObject var vault: VaultController
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Identity.Provider = .github
    @State private var name = ""
    @State private var token = ""
    @State private var scope = ""
    @State private var awsProfile = ""
    @State private var status: String?
    @State private var verifying = false
    @State private var error: String?

    static var awsProfiles: [String] {
        let path = NSHomeDirectory() + "/.aws/config"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
            let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner == "default" { return "default" }
            return inner.hasPrefix("profile ") ? String(inner.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil
        }
    }

    var hint: String {
        switch provider {
        case .cloudflare: "In Cloudflare: My Profile → API Tokens → Create Token → use the **Edit Cloudflare Workers** template. Under Account Resources, include only this account. Add D1, Queues or Hyperdrive permissions if the project uses them."
        case .github: "github.com → Settings → Developer settings → Fine-grained tokens. Or in a terminal: redact id add github NAME --from-gh USER"
        case .vercel: "vercel.com → Account Settings → Tokens. Scope it to the team you deploy to."
        case .supabase: "supabase.com/dashboard/account/tokens"
        case .aws: "Pick a profile from ~/.aws/config. Redact sets AWS_PROFILE; your credentials stay with the AWS CLI."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.m) {
                BrandTile(brand: .of(provider), size: 36)
                Text("Add account").font(TextStyle.title).foregroundStyle(Palette.ink)
            }
            Picker("Provider", selection: $provider) {
                ForEach(Identity.Provider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(LocalizedStringKey(hint)).font(TextStyle.small).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                if let link = provider.tokenPage {
                    Link("Open the token page", destination: link).font(TextStyle.small).foregroundStyle(Palette.accentText)
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                TextField("Name (e.g. work, acme)", text: $name)
                if !name.isEmpty, slug != name {
                    Text(slug.isEmpty ? "Use letters or numbers in the name." : "Saved as \(slug). Names are used in the terminal, so they can't have spaces.")
                        .font(TextStyle.caption).foregroundStyle(Palette.ink3)
                }
            }
            if provider == .aws {
                let profiles = Self.awsProfiles
                if profiles.isEmpty {
                    TextField("Profile name", text: $awsProfile)
                } else {
                    Picker("Profile", selection: $awsProfile) {
                        Text("Choose…").tag("")
                        ForEach(profiles, id: \.self) { Text($0).tag($0) }
                    }
                }
            } else {
                SecureField("Token", text: $token)
                if let label = provider.scopeLabel {
                    TextField(provider == .cloudflare ? "\(label) (optional but recommended)" : "\(label) (optional)", text: $scope)
                }
            }
            if let status { Text(status).font(TextStyle.small).foregroundStyle(Palette.ink) }
            if let error { Notice(symbol: "exclamationmark.triangle.fill", text: error, tone: .danger) }
            HStack {
                if provider == .cloudflare {
                    Button("Verify token") { verifyCloudflare() }.buttonStyle(.secondary).disabled(token.isEmpty || verifying)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(Space.xl)
        .frame(width: 560)
        .canvas()
    }

    /// The name as stored: lowercased when it needed fixing, spaces and other characters turned into "-".
    var slug: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let ok: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        if !trimmed.isEmpty, trimmed == name, trimmed.allSatisfy(ok) { return trimmed }
        var out = ""
        for ch in trimmed.lowercased() {
            if ok(ch) { out.append(ch) } else if out.last != "-" { out.append("-") }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    var canSave: Bool {
        !slug.isEmpty && (provider == .aws ? !awsProfile.isEmpty : !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Calls Cloudflare's token verify endpoint with the user's own token (sent only to api.cloudflare.com).
    private func verifyCloudflare() {
        verifying = true
        var request = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!)
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        Task {
            defer { verifying = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let ok = object?["success"] as? Bool ?? false
                let state = (object?["result"] as? [String: Any])?["status"] as? String ?? "unknown"
                status = ok ? "✓ Token is \(state)." : "✗ Cloudflare rejected this token."
                if ok, scope.isEmpty, let account = try await soleAccount() {
                    scope = account.id
                    status = "✓ Token is \(state). Account ID filled in for \(account.name)."
                }
            } catch {
                status = "Couldn't reach Cloudflare: \(error.localizedDescription)"
            }
        }
    }

    /// The token's account, when it can reach exactly one (sent only to api.cloudflare.com).
    private func soleAccount() async throws -> (id: String, name: String)? {
        var request = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/accounts?per_page=2")!)
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let accounts = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [[String: Any]] ?? []
        guard accounts.count == 1, let id = accounts[0]["id"] as? String else { return nil }
        return (id, accounts[0]["name"] as? String ?? id)
    }

    private func save() {
        let name = slug
        if vault.data.identities.contains(where: { $0.name == name }) {
            error = "An account called \(name) already exists. Names must be unique."
            return
        }
        if provider == .aws {
            let identity = Identity(provider: .aws, name: name, mode: .awsProfile(name: awsProfile))
            vault.update { $0.identities.append(identity) }
        } else {
            let item = Item(kind: .apiKey, name: "\(provider.displayName) token · \(name)",
                            value: token.trimmingCharacters(in: .whitespacesAndNewlines), tags: [provider.rawValue, "identity"])
            let identity = Identity(provider: provider, name: name,
                                    mode: .apiToken(itemID: item.id, accountID: scope.isEmpty ? nil : scope))
            vault.update { data in
                data.items.append(item)
                data.identities.append(identity)
            }
        }
        dismiss()
    }
}

/// A folder an account is bound to, with an Unbind action.
struct BoundFolderRow: View {
    let path: String
    let unbind: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            PathLabel(path: path, font: TextStyle.mono)
            Spacer(minLength: Space.s)
            Button("Unbind", action: unbind).buttonStyle(.quiet)
        }
        .padding(.leading, Space.s)
        .frame(height: 28)
        .sunken()
        .padding(.leading, 40)
    }
}

extension Identity.Provider {
    /// Where the user creates a token for this provider.
    var tokenPage: URL? {
        switch self {
        case .cloudflare: URL(string: "https://dash.cloudflare.com/profile/api-tokens")
        case .github: URL(string: "https://github.com/settings/personal-access-tokens")
        case .vercel: URL(string: "https://vercel.com/account/settings/tokens")
        case .supabase: URL(string: "https://supabase.com/dashboard/account/tokens")
        case .aws: nil
        }
    }
}
