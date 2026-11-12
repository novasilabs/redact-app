import CryptoKit
import Foundation

// Backup and restore (PRD §6.9, §6.11).
//
// A backup is a `.redact` file in the vault's own format: the chosen records sealed with the vault key,
// plus the vault's Recovery Key protector(s), copied as they are. So the Recovery Key the user already
// has opens it, and Redact never needs to know that key. Touch ID protectors are left out: they are
// bound to this Mac's Secure Enclave and useless anywhere else.

/// Plaintext header of a backup file. Informational only (not authenticated): never trusted for access.
public struct BackupInfo: Codable, Sendable, Equatable {
    public var createdAt: Date
    public var partial: Bool
    public var projects: Int
    public var keys: Int
    public var codeSets: Int
    public var accounts: Int

    public init(createdAt: Date = Date(), partial: Bool, projects: Int, keys: Int, codeSets: Int, accounts: Int) {
        self.createdAt = createdAt
        self.partial = partial
        self.projects = projects
        self.keys = keys
        self.codeSets = codeSets
        self.accounts = accounts
    }
}

/// What to put in a backup. Dependencies are added automatically (a project brings its variables and
/// the shared keys they link to; an account brings its token).
public struct BackupSelection: Sendable, Equatable {
    public var projectIDs: Set<UUID>
    public var itemIDs: Set<UUID>
    public var identityIDs: Set<UUID>
    public var includeActivity: Bool

    public init(projectIDs: Set<UUID> = [], itemIDs: Set<UUID> = [], identityIDs: Set<UUID> = [], includeActivity: Bool = false) {
        self.projectIDs = projectIDs
        self.itemIDs = itemIDs
        self.identityIDs = identityIDs
        self.includeActivity = includeActivity
    }

    /// Everything in the vault.
    public static func all(_ data: VaultData) -> BackupSelection {
        BackupSelection(projectIDs: Set(data.projects.map(\.id)),
                        itemIDs: Set(data.items.filter { $0.kind != .variable }.map(\.id)),
                        identityIDs: Set(data.identities.map(\.id)),
                        includeActivity: true)
    }

    public func isEverything(in data: VaultData) -> Bool {
        let all = Self.all(data)
        return projectIDs.isSuperset(of: all.projectIDs) && itemIDs.isSuperset(of: all.itemIDs)
            && identityIDs.isSuperset(of: all.identityIDs) && includeActivity
    }
}

extension VaultData {
    /// The part of the vault a selection covers, including what it depends on.
    public func subset(_ selection: BackupSelection) -> VaultData {
        var out = VaultData()
        out.projects = projects.filter { selection.projectIDs.contains($0.id) }
        let variables = items.filter { $0.kind == .variable && $0.projectID.map(selection.projectIDs.contains) == true }
        let identities = self.identities.filter { selection.identityIDs.contains($0.id) }
        var itemIDs = selection.itemIDs
        itemIDs.formUnion(variables.compactMap(\.linkedItemID))
        itemIDs.formUnion(identities.compactMap(\.tokenItemID))
        let variableIDs = Set(variables.map(\.id))
        out.items = items.filter { variableIDs.contains($0.id) || ($0.kind != .variable && itemIDs.contains($0.id)) }
        out.identities = identities
        out.activity = selection.includeActivity ? activity : []
        return out
    }
}

public enum VaultBackup {
    /// Builds a backup file from the unlocked vault. Throws if the vault has no Recovery Key protector.
    public static func make(from vault: VaultFile, data: VaultData, key: SymmetricKey, selection: BackupSelection) throws -> VaultFile {
        let recovery = vault.protectors.filter { $0.kind == .recovery }
        guard !recovery.isEmpty else { throw VaultError.noProtector("Recovery Key") }
        let subset = data.subset(selection)
        var file = VaultFile(format: VaultFile.currentFormat, protectors: recovery,
                             records: try VaultFile.seal(subset, previous: nil, key: key))
        file.backup = BackupInfo(partial: !selection.isEverything(in: data),
                                 projects: subset.projects.count,
                                 keys: subset.items.filter { $0.kind == .apiKey || $0.kind == .note }.count,
                                 codeSets: subset.items.filter { $0.kind == .backupCodes }.count,
                                 accounts: subset.identities.count)
        return file
    }

    /// Opens a backup with the Recovery Key of the vault it came from.
    public static func open(_ file: VaultFile, recoveryKey: Data) throws -> (data: VaultData, key: SymmetricKey) {
        let key = try file.unlock(secret: recoveryKey, kind: .recovery)
        return (try file.open(key: key), key)
    }

    /// Turns a backup into this Mac's vault (nothing to merge into): keeps its Recovery Key protectors,
    /// drops any Touch ID protector from another Mac, and re-seals `data` (after path remapping).
    public static func adopt(_ backup: VaultFile, data: VaultData, key: SymmetricKey, enclave: VaultFile.Protector?) throws -> VaultFile {
        var protectors = backup.protectors.filter { $0.kind == .recovery }
        if let enclave { protectors.insert(enclave, at: 0) }
        return VaultFile(format: VaultFile.currentFormat, protectors: protectors,
                         records: try VaultFile.seal(data, previous: nil, key: key))
    }
}

// MARK: - Restore plan (merge into an existing vault)

public struct RestorePlan: Sendable {
    public enum Kind: String, Sendable { case project, key, codes, note, account }
    public enum Status: String, Sendable { case new, changed, same }

    public struct Row: Identifiable, Sendable {
        public var id: UUID            // the backup's ID for this entity
        public var kind: Kind
        public var name: String
        public var detail: String
        public var status: Status
        public var selected: Bool
    }

    public var rows: [Row]
    public let backup: VaultData
    /// Backup project ID → existing project ID, for projects matched by path rather than ID.
    let projectMatches: [UUID: UUID]

    public init(backup: VaultData, current: VaultData) {
        self.backup = backup
        var matches: [UUID: UUID] = [:]
        var rows: [Row] = []

        for project in backup.projects {
            let mine = backup.items.filter { $0.kind == .variable && $0.projectID == project.id }
            let existing = current.projects.first { $0.id == project.id } ?? current.projects.first { $0.path == project.path }
            var status = Status.new
            if let existing {
                matches[project.id] = existing.id
                let theirs = current.items.filter { $0.kind == .variable && $0.projectID == existing.id }
                let same = existing.environments == project.environments && mine.count == theirs.count && mine.allSatisfy { variable in
                    theirs.contains { $0.environment == variable.environment && $0.name == variable.name
                        && current.resolvedValue(of: $0) == backup.resolvedValue(of: variable) }
                }
                status = same ? .same : .changed
            }
            let envs = Set(mine.compactMap(\.environment)).count
            rows.append(Row(id: project.id, kind: .project, name: project.name,
                            detail: "\(mine.count) variable\(mine.count == 1 ? "" : "s") in \(envs) environment\(envs == 1 ? "" : "s")",
                            status: status, selected: status != .same))
        }

        let tokenIDs = Set(backup.identities.compactMap(\.tokenItemID))
        for item in backup.items where item.kind != .variable && !tokenIDs.contains(item.id) {
            let kind: Kind = item.kind == .backupCodes ? .codes : (item.kind == .note ? .note : .key)
            let status: Status
            if let existing = current.items.first(where: { $0.id == item.id }) {
                status = existing.value == item.value && existing.codes.map(\.code) == item.codes.map(\.code) && existing.name == item.name ? .same : .changed
            } else {
                status = .new
            }
            let detail = kind == .codes ? "\(item.codes.filter { $0.usedAt == nil }.count) of \(item.codes.count) codes left" : (kind == .note ? "Note" : "Key")
            rows.append(Row(id: item.id, kind: kind, name: item.name, detail: detail, status: status, selected: status != .same))
        }

        for identity in backup.identities {
            let token = identity.tokenItemID.flatMap { id in backup.items.first { $0.id == id }?.value }
            let status: Status
            if let existing = current.identities.first(where: { $0.id == identity.id }) ?? current.identities.first(where: { $0.name == identity.name }) {
                let existingToken = existing.tokenItemID.flatMap { id in current.items.first { $0.id == id }?.value }
                status = existing.mode == identity.mode && existing.boundPaths == identity.boundPaths && existingToken == token ? .same : .changed
            } else {
                status = .new
            }
            rows.append(Row(id: identity.id, kind: .account, name: identity.name,
                            detail: "\(identity.provider.displayName) account, \(identity.boundPaths.count) folder\(identity.boundPaths.count == 1 ? "" : "s")",
                            status: status, selected: status != .same))
        }
        self.rows = rows
        self.projectMatches = matches
    }

    /// Writes the selected rows into `data`. Restored entities replace their existing copies; nothing
    /// that isn't selected is touched. `remap` rewrites folder paths (e.g. a different home folder).
    public func apply(to data: inout VaultData, remap: (String) -> String = { $0 }) {
        let selected = Set(rows.filter(\.selected).map(\.id))

        func upsert(_ item: Item) {
            if let index = data.items.firstIndex(where: { $0.id == item.id }) { data.items[index] = item } else { data.items.append(item) }
        }

        for project in backup.projects where selected.contains(project.id) {
            let targetID = projectMatches[project.id] ?? project.id
            var restored = project
            restored.id = targetID
            restored.path = remap(project.path)
            if let index = data.projects.firstIndex(where: { $0.id == targetID }) {
                var environments = data.projects[index].environments
                for env in project.environments where !environments.contains(env) { environments.append(env) }
                restored.environments = environments
                data.projects[index] = restored
            } else {
                data.projects.append(restored)
            }
            for variable in backup.items where variable.kind == .variable && variable.projectID == project.id {
                // Shared keys the variable links to come along, so the link keeps working.
                if let linked = variable.linkedItemID, let key = backup.items.first(where: { $0.id == linked }),
                   !data.items.contains(where: { $0.id == linked }) {
                    upsert(key)
                }
                var restoredVariable = variable
                restoredVariable.projectID = targetID
                data.items.removeAll { $0.kind == .variable && $0.projectID == targetID && $0.environment == variable.environment
                    && $0.name == variable.name && $0.id != variable.id }
                upsert(restoredVariable)
            }
        }

        for item in backup.items where item.kind != .variable && selected.contains(item.id) {
            upsert(item)
        }

        for identity in backup.identities where selected.contains(identity.id) {
            if let tokenID = identity.tokenItemID, let token = backup.items.first(where: { $0.id == tokenID }) { upsert(token) }
            var restored = identity
            restored.boundPaths = identity.boundPaths.map(remap)
            // A folder belongs to one account per provider: take it away from any other.
            for i in data.identities.indices where data.identities[i].id != identity.id && data.identities[i].provider == identity.provider {
                data.identities[i].boundPaths.removeAll { restored.boundPaths.contains($0) }
            }
            data.identities.removeAll { $0.name == identity.name && $0.id != identity.id }
            if let index = data.identities.firstIndex(where: { $0.id == identity.id }) {
                data.identities[index] = restored
            } else {
                data.identities.append(restored)
            }
        }

        let known = Set(data.activity.map(\.id))
        data.activity = (data.activity + backup.activity.filter { !known.contains($0.id) })
            .sorted { $0.date > $1.date }
            .prefix(VaultData.activityLimit)
            .map { $0 }
    }
}

// MARK: - Path remapping

/// Project folders and account bindings store absolute paths. On a new Mac the home folder (or the
/// whole layout) may differ, so restore offers to rewrite a prefix.
public struct PathRemap: Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    public func apply(_ path: String) -> String {
        guard !from.isEmpty, path == from || path.hasPrefix(from + "/") else { return path }
        return to + path.dropFirst(from.count)
    }

    /// Every folder path in `data` (projects and account bindings).
    public static func paths(in data: VaultData) -> [String] {
        data.projects.map(\.path) + data.identities.flatMap(\.boundPaths)
    }

    /// If the paths live under another user's home folder (`/Users/<someone>`) and are missing here,
    /// suggests moving them under `home`.
    public static func suggest(for paths: [String], home: String = NSHomeDirectory(),
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> PathRemap? {
        let homes = paths.compactMap { path -> String? in
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "Users" else { return nil }
            return "/Users/\(parts[1])"
        }
        guard let common = Dictionary(grouping: homes, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key,
              common != home else { return nil }
        let under = paths.filter { $0 == common || $0.hasPrefix(common + "/") }
        guard !under.isEmpty, under.contains(where: { !exists($0) }) else { return nil }
        return PathRemap(from: common, to: home)
    }

    /// Paths that still don't exist after remapping.
    public static func missing(in paths: [String], remap: PathRemap?,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        paths.map { remap?.apply($0) ?? $0 }.filter { !exists($0) }
    }
}
