import Foundation

/// A secret or note stored in the vault.
public struct Item: Codable, Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case apiKey        // standalone key or token
        case variable      // belongs to a project + environment
        case backupCodes   // set of one-time codes
        case note          // recovery key, free text
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    public var value: String
    public var notes: String
    public var tags: [String]
    /// For `.variable`: the owning project and environment.
    public var projectID: UUID?
    public var environment: String?
    /// For `.variable`: if set, the value comes from this item instead of `value` ("linked secret").
    public var linkedItemID: UUID?
    public var codes: [BackupCode]
    public var createdAt: Date
    public var updatedAt: Date
    public var rotatedAt: Date?

    public init(id: UUID = UUID(), kind: Kind, name: String, value: String = "", notes: String = "",
                tags: [String] = [], projectID: UUID? = nil, environment: String? = nil,
                linkedItemID: UUID? = nil, codes: [BackupCode] = [], createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.value = value
        self.notes = notes
        self.tags = tags
        self.projectID = projectID
        self.environment = environment
        self.linkedItemID = linkedItemID
        self.codes = codes
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.rotatedAt = nil
    }
}

public struct BackupCode: Codable, Sendable, Equatable, Hashable {
    public var code: String
    public var usedAt: Date?
    public init(code: String, usedAt: Date? = nil) {
        self.code = code
        self.usedAt = usedAt
    }
}

public struct Project: Codable, Identifiable, Sendable, Equatable, Hashable {
    public static let defaultEnvironments = ["development", "preview", "production"]

    public var id: UUID
    public var name: String
    /// Real (symlink-resolved) absolute path.
    public var path: String
    public var environments: [String]
    public var defaultEnvironment: String

    public init(id: UUID = UUID(), name: String, path: String,
                environments: [String] = Project.defaultEnvironments, defaultEnvironment: String = "development") {
        self.id = id
        self.name = name
        self.path = path
        self.environments = environments
        self.defaultEnvironment = defaultEnvironment
    }
}

/// A cloud account login that can be bound to folders.
public struct Identity: Codable, Identifiable, Sendable, Equatable, Hashable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case cloudflare
    }

    public enum Mode: Codable, Sendable, Equatable, Hashable {
        /// Wrangler-managed OAuth profile (`wrangler auth create <name>`). Bindings live in Wrangler.
        case wranglerProfile(name: String)
        /// API token stored as a vault item, injected by `redact run` for bound folders.
        case apiToken(itemID: UUID, accountID: String?)
    }

    public var id: UUID
    public var provider: Provider
    public var name: String
    public var mode: Mode
    /// Folder bindings for `.apiToken` mode (Wrangler profiles keep their own).
    public var boundPaths: [String]

    public init(id: UUID = UUID(), provider: Provider = .cloudflare, name: String, mode: Mode, boundPaths: [String] = []) {
        self.id = id
        self.provider = provider
        self.name = name
        self.mode = mode
        self.boundPaths = boundPaths
    }
}

public struct ActivityEntry: Codable, Identifiable, Sendable, Equatable, Hashable {
    public enum Outcome: String, Codable, Sendable {
        case approved, denied, autoApproved, failed
        /// Allowed by an earlier time-boxed grant, without a new prompt.
        case granted
    }

    public var id: UUID
    public var date: Date
    public var caller: String       // executable name
    public var agent: String?       // detected AI agent
    public var command: String
    public var directory: String
    public var variableNames: [String]
    public var outcome: Outcome

    public init(id: UUID = UUID(), date: Date = Date(), caller: String, agent: String?, command: String,
                directory: String, variableNames: [String], outcome: Outcome) {
        self.id = id
        self.date = date
        self.caller = caller
        self.agent = agent
        self.command = command
        self.directory = directory
        self.variableNames = variableNames
        self.outcome = outcome
    }
}

/// Everything inside the vault, decrypted. Only ever held in memory by the app.
public struct VaultData: Codable, Sendable, Equatable {
    public var items: [Item] = []
    public var projects: [Project] = []
    public var identities: [Identity] = []
    public var activity: [ActivityEntry] = []

    public init() {}

    public static let activityLimit = 500

    public mutating func log(_ entry: ActivityEntry) {
        activity.insert(entry, at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }

    /// The project whose path is the nearest ancestor of `directory` (or the directory itself).
    public func project(containing directory: String) -> Project? {
        let dir = WranglerProfiles.realPath(directory)
        return projects
            .filter { dir == $0.path || dir.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    public func variables(projectID: UUID, environment: String) -> [Item] {
        items.filter { $0.kind == .variable && $0.projectID == projectID && $0.environment == environment }
            .sorted { $0.name < $1.name }
    }

    /// Value of an item, following a link if it has one.
    public func resolvedValue(of item: Item) -> String {
        guard let linked = item.linkedItemID, let target = items.first(where: { $0.id == linked }) else { return item.value }
        return target.value
    }

    /// Name → value for a project environment, with links resolved.
    public func environment(projectID: UUID, environment: String) -> [String: String] {
        variables(projectID: projectID, environment: environment)
            .reduce(into: [:]) { $0[$1.name] = resolvedValue(of: $1) }
    }

    /// Variables in other places that reference `item`.
    public func usages(of item: Item) -> [Item] {
        items.filter { $0.linkedItemID == item.id }
    }

    /// The API-token identity bound to `directory`, if any (longest bound path wins).
    public func tokenIdentity(for directory: String) -> (Identity, String)? {
        let dir = WranglerProfiles.realPath(directory)
        var best: (Identity, String)?
        for identity in identities {
            for path in identity.boundPaths where dir == path || dir.hasPrefix(path + "/") {
                if best == nil || path.count > best!.1.count { best = (identity, path) }
            }
        }
        return best
    }
}
