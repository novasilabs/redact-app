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
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Identities").font(.title2.bold())
                    Spacer()
                    Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                Text("Bind each Cloudflare account to the folders it owns. Inside a bound folder, plain `wrangler deploy` uses that account. No more logout/login.")
                    .foregroundStyle(.secondary)

                warnings

                GroupBox("Wrangler profiles") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(profiles, id: \.name) { profile in profileRow(profile) }
                        Divider()
                        HStack {
                            TextField("new profile name (e.g. acme)", text: $newProfile)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                            Button("Log in and create") { createProfile() }
                                .disabled(!isValidProfileName(newProfile) || busy != nil)
                            Text("Opens Cloudflare in your browser.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Other accounts") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("GitHub, Vercel and Supabase tokens and Cloudflare API tokens are stored in this vault and set for bound folders by `redact run` (and by the shell wrappers). AWS identities just pick a profile from ~/.aws/config.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(Identity.Provider.allCases, id: \.self) { provider in
                            let list = vault.data.identities.filter { $0.provider == provider }
                            if !list.isEmpty {
                                Text(provider.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                                ForEach(list) { identity in tokenRow(identity) }
                            }
                        }
                        Button("Add account…") { showTokenSheet = true }
                    }
                    .padding(8)
                }

                if let busy { ProgressView(busy).controlSize(.small) }
                if let output {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(20)
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showTokenSheet) { TokenIdentitySheet() }
        .navigationTitle("Identities")
    }

    @ViewBuilder private var warnings: some View {
        if profiles.contains(where: { !$0.encrypted }) {
            HStack {
                Label("Some Wrangler logins are stored as plaintext files.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Move to Keychain") { runWrangler("Moving logins to the Keychain…") { await WranglerCLI.moveTokensToKeychain() } }
            }
        }
        if !broken.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("These bindings never apply (the path is a symlink, Wrangler looks up the real path):", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                ForEach(broken, id: \.self) { path in
                    HStack {
                        Text(path).font(.caption.monospaced())
                        Button("Fix") { fixBinding(path) }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func profileRow(_ profile: WranglerProfiles.Profile) -> some View {
        let paths = bindings.filter { $0.value == profile.name }.map(\.key).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "cloud").foregroundStyle(.orange)
                Text(profile.name).font(.headline)
                if profile.name == "default" { Text("fallback everywhere else").font(.caption).foregroundStyle(.secondary) }
                Image(systemName: profile.encrypted ? "lock.fill" : "lock.open")
                    .foregroundStyle(profile.encrypted ? Color.secondary : Color.orange)
                    .help(profile.encrypted ? "Stored in the Keychain" : "Stored as a plaintext file")
                if let who = whoami[profile.name] { Text(who).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if profile.name != "default" {
                    Button("Bind folder…") { bind(profile.name) }
                    Menu {
                        if let first = paths.first { Button("Check account") { check(profile.name, in: first) } }
                        Button("Re-authenticate") { runWrangler("Re-authenticating \(profile.name)…") { await WranglerCLI.createProfile(profile.name) } }
                        Divider()
                        Button("Delete profile", role: .destructive) {
                            runWrangler("Deleting \(profile.name)…") { await WranglerCLI.run(["auth", "delete", profile.name]) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
            }
            ForEach(paths, id: \.self) { path in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(abbreviate(path)).font(.callout.monospaced()).lineLimit(1).truncationMode(.head).help(path)
                    Spacer()
                    Button("Unbind") {
                        runWrangler("Unbinding…") { await WranglerCLI.deactivate(directory: path) }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 24)
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: Self.icon(identity.provider)).foregroundStyle(.tint)
                Text(identity.name).font(.headline)
                switch identity.mode {
                case let .apiToken(_, accountID):
                    if let accountID { Text(accountID).font(.caption.monospaced()).foregroundStyle(.secondary) }
                case let .awsProfile(name):
                    Text("profile \(name)").font(.caption.monospaced()).foregroundStyle(.secondary)
                case .wranglerProfile:
                    EmptyView()
                }
                Spacer()
                Button("Bind folder…") { bindToken(identity) }
                Button(role: .destructive) {
                    vault.update { data in
                        if case let .apiToken(itemID, _) = identity.mode { data.items.removeAll { $0.id == itemID } }
                        data.identities.removeAll { $0.id == identity.id }
                    }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            ForEach(identity.boundPaths, id: \.self) { path in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(abbreviate(path)).font(.callout.monospaced()).lineLimit(1).truncationMode(.head).help(path)
                    Spacer()
                    Button("Unbind") {
                        vault.update { data in
                            if let i = data.identities.firstIndex(where: { $0.id == identity.id }) { data.identities[i].boundPaths.removeAll { $0 == path } }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 24)
            }
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
        case .cloudflare: "dash.cloudflare.com → My Profile → API Tokens. Scope it to one account and the permissions you deploy with."
        case .github: "github.com → Settings → Developer settings → Fine-grained tokens. Or in a terminal: redact id add github NAME --from-gh USER"
        case .vercel: "vercel.com → Account Settings → Tokens. Scope it to the team you deploy to."
        case .supabase: "supabase.com/dashboard/account/tokens"
        case .aws: "Pick a profile from ~/.aws/config. Redact sets AWS_PROFILE; your credentials stay with the AWS CLI."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add account").font(.title2.bold())
            Picker("Provider", selection: $provider) {
                ForEach(Identity.Provider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name (e.g. work, acme)", text: $name)
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
            if let status { Text(status).font(.callout) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if provider == .cloudflare {
                    Button("Verify token") { verifyCloudflare() }.disabled(token.isEmpty || verifying)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 560)
    }

    var canSave: Bool {
        let validName = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return validName && (provider == .aws ? !awsProfile.isEmpty : !token.isEmpty)
    }

    /// Calls Cloudflare's token verify endpoint with the user's own token (sent only to api.cloudflare.com).
    private func verifyCloudflare() {
        verifying = true
        var request = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task {
            defer { verifying = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let ok = object?["success"] as? Bool ?? false
                let state = (object?["result"] as? [String: Any])?["status"] as? String ?? "unknown"
                status = ok ? "✓ Token is \(state)." : "✗ Cloudflare rejected this token."
            } catch {
                status = "Couldn't reach Cloudflare: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
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
