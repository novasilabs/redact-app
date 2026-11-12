import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import RedactCore

/// Owns the vault: the only place the vault key and decrypted data live.
@MainActor
final class VaultController: ObservableObject {
    enum State: Equatable { case noVault, locked, unlocked }

    @Published private(set) var state: State = .locked
    @Published var data = VaultData()
    @Published var lastError: String?

    private var file: VaultFile?
    private var key: SymmetricKey?
    private var context: LAContext?
    private var unlockedAt: Date?
    private(set) var lastActivity = Date()

    // Locking policy (PRD §6.12).
    var idleLimit: TimeInterval = 10 * 60
    var maximumSessionAge: TimeInterval = 12 * 60 * 60

    init() {
        state = FileManager.default.fileExists(atPath: RedactPaths.vault.path) ? .locked : .noVault
        observeLockEvents()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkTimers() }
        }
    }

    // MARK: - Setup

    /// Creates a new vault. Returns the Recovery Key text to show the user once.
    func createVault() throws -> String {
        let vaultKey = SymmetricKey(size: .bits256)
        let recovery = RecoveryKey.generate()
        var protectors = [try VaultFile.secretProtector(for: vaultKey, secret: recovery, kind: .recovery)]
        protectors.insert(try VaultFile.enclaveProtector(for: vaultKey, requireBiometry: Self.biometryAvailable), at: 0)
        let newFile = VaultFile(format: VaultFile.currentFormat, protectors: protectors,
                                records: try VaultFile.seal(VaultData(), previous: nil, key: vaultKey))
        try newFile.write(to: RedactPaths.vault)
        file = newFile
        key = vaultKey
        data = VaultData()
        unlockedAt = Date()
        touch()
        state = .unlocked
        return RecoveryKey.format(recovery)
    }

    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    // MARK: - Lock / unlock

    func unlock(reason: String = "unlock your Redact vault") async -> Bool {
        if state == .unlocked { touch(); return true }
        guard state == .locked else { return false }
        do {
            let loaded = try VaultFile.load(from: RedactPaths.vault)
            let context = LAContext()
            context.localizedReason = reason
            context.touchIDAuthenticationAllowableReuseDuration = 0
            // Unwrapping with the enclave key triggers the Touch ID prompt itself.
            let vaultKey = try await Task.detached { try loaded.unlockWithEnclave(context: context) }.value
            try finishUnlock(file: loaded, key: vaultKey, context: context)
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    func unlock(recoveryKey text: String) -> Bool {
        guard let secret = RecoveryKey.parse(text) else {
            lastError = "That doesn't look like a Recovery Key (13 groups of 4 characters)."
            return false
        }
        do {
            let loaded = try VaultFile.load(from: RedactPaths.vault)
            let vaultKey = try loaded.unlock(secret: secret, kind: .recovery)
            try finishUnlock(file: loaded, key: vaultKey, context: nil)
            // If the enclave key is gone (e.g. fingerprints changed), re-enrol this Mac.
            if (try? loaded.unlockWithEnclave(context: LAContext())) == nil { try reenrollEnclave() }
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    private func finishUnlock(file loaded: VaultFile, key vaultKey: SymmetricKey, context: LAContext?) throws {
        data = try loaded.open(key: vaultKey)
        file = loaded
        key = vaultKey
        self.context = context
        unlockedAt = Date()
        touch()
        lastError = nil
        state = .unlocked
    }

    private func reenrollEnclave() throws {
        guard let key, var current = file else { return }
        current.protectors.removeAll { $0.kind == .enclave }
        current.protectors.insert(try VaultFile.enclaveProtector(for: key, requireBiometry: Self.biometryAvailable), at: 0)
        try current.write(to: RedactPaths.vault)
        file = current
    }

    func lock() {
        guard state == .unlocked else { return }
        key = nil
        context?.invalidate()
        context = nil
        file = nil
        data = VaultData()
        unlockedAt = nil
        state = .locked
        Clipboard.clearIfOurs()
        NotificationCenter.default.post(name: .redactDidLock, object: nil)
    }

    func touch() { lastActivity = Date() }

    private func checkTimers() {
        guard state == .unlocked else { return }
        if Date().timeIntervalSince(lastActivity) > idleLimit { lock() }
        if let unlockedAt, Date().timeIntervalSince(unlockedAt) > maximumSessionAge { lock() }
    }

    private func observeLockEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }

    // MARK: - Changes

    /// Applies a change and saves. Every mutation goes through here.
    func update(_ change: (inout VaultData) -> Void) {
        guard state == .unlocked, let key else { return }
        var next = data
        change(&next)
        do {
            let records = try VaultFile.seal(next, previous: file, key: key)
            var updated = file ?? VaultFile(format: VaultFile.currentFormat, protectors: [], records: [])
            updated.records = records
            try updated.write(to: RedactPaths.vault)
            file = updated
            data = next
            touch()
        } catch {
            lastError = "Couldn't save the vault: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == LAError.errorDomain {
            switch LAError.Code(rawValue: ns.code) {
            case .userCancel, .appCancel, .systemCancel: return "Unlock cancelled."
            case .biometryLockout: return "Touch ID is locked. Unlock your Mac with its password, then try again."
            default: break
            }
        }
        if let vaultError = error as? VaultError { return vaultError.localizedDescription }
        return error.localizedDescription
    }
}

extension Notification.Name {
    static let redactDidLock = Notification.Name("redactDidLock")
}

/// Clipboard handling: concealed type (clipboard managers skip it) and auto-clear.
@MainActor
enum Clipboard {
    private static var lastChangeCount: Int?
    static var clearAfter: TimeInterval = 60

    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let changeCount = pasteboard.changeCount
        lastChangeCount = changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
            if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
        }
    }

    static func clearIfOurs() {
        if let lastChangeCount, NSPasteboard.general.changeCount == lastChangeCount {
            NSPasteboard.general.clearContents()
        }
    }
}
