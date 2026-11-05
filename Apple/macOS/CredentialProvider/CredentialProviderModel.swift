import AuthenticationServices
import Foundation

import UPasswordsCore
import UPasswordsPersistence

/// Session state for the macOS system credential provider.
@MainActor
final class CredentialProviderModel: ObservableObject {
    enum Stage {
        case noVault
        case locked
        case unlocked
    }

    @Published private(set) var stage: Stage = .locked
    @Published private(set) var cards: [Card] = []
    @Published var masterInput = ""
    @Published private(set) var showUnlockError = false
    @Published private(set) var biometricUnlockAvailable = false
    @Published private(set) var biometricUnlockInProgress = false

    private var context: ASCredentialProviderExtensionContext?
    private var serviceIdentifiers: [String] = []
    private var requestedRecordIdentifier: String?
    private var biometricUnlockAttempted = false
    private var requestID = UUID()

    private static let appGroup = "2CV6VKVD26.com.upasswords.shared"
    private static let snapshotDirectory = "CredentialProvider"
    private static let keychainAccessGroup = PasswordStore.credentialProviderAccessGroup

    var serviceLabel: String? {
        guard let identifier = serviceIdentifiers.first,
              let components = URLComponents(string: identifier) else { return nil }
        return components.host ?? identifier
    }

    /// Attaches a password list request from the system.
    func attach(context: ASCredentialProviderExtensionContext,
                serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        self.context = context
        requestID = UUID()
        self.serviceIdentifiers = serviceIdentifiers.compactMap {
            Self.normalizedServiceURL($0.identifier)
        }
        requestedRecordIdentifier = nil
        stage = .locked
        cards = []
        showUnlockError = false
        masterInput = ""
        biometricUnlockAvailable = false
        biometricUnlockInProgress = false
        biometricUnlockAttempted = false
        updateBiometricUnlockAvailability()
        Log.info("autofill", "macOS credential list requested: services=\(self.serviceIdentifiers.count)")
    }

    /// Attaches a request that was opened from a specific credential suggestion.
    func attach(context: ASCredentialProviderExtensionContext,
                request: any ASCredentialRequest) {
        self.context = context
        requestID = UUID()
        serviceIdentifiers = [
            Self.normalizedServiceURL(request.credentialIdentity.serviceIdentifier.identifier)
        ].compactMap { $0 }
        requestedRecordIdentifier = request.credentialIdentity.recordIdentifier
        stage = .locked
        cards = []
        showUnlockError = false
        masterInput = ""
        biometricUnlockAvailable = false
        biometricUnlockInProgress = false
        biometricUnlockAttempted = false
        updateBiometricUnlockAvailability()
        Log.info("autofill", "macOS credential request opened")
    }

    /// Unlocks the encrypted snapshot shared by the containing app and extension.
    func unlock() {
        guard let snapshotRoot = Self.snapshotRoot,
              let databaseName = Self.currentDatabaseName(in: snapshotRoot) else {
            stage = .noVault
            Log.warn("autofill", "macOS credential provider snapshot unavailable")
            return
        }
        unlock(password: masterInput, databaseName: databaseName, showsPasswordError: true)
    }

    /// Attempts Touch ID once when the credential picker first appears.
    func attemptBiometricUnlockIfAvailable() {
        guard !biometricUnlockAttempted else { return }
        biometricUnlockAttempted = true
        unlockWithBiometrics()
    }

    /// Prompts for Touch ID to unlock the shared vault snapshot.
    func unlockWithBiometrics() {
        guard biometricUnlockAvailable, !biometricUnlockInProgress,
              let accessGroup = Self.keychainAccessGroup else { return }
        guard let snapshotRoot = Self.snapshotRoot,
              let databaseName = Self.currentDatabaseName(in: snapshotRoot) else {
            stage = .noVault
            Log.warn("autofill", "macOS credential provider snapshot unavailable for biometric unlock")
            return
        }

        biometricUnlockInProgress = true
        let requestID = self.requestID
        let startedAt = Date()
        Log.info("autofill", "macOS credential provider Touch ID unlock started: database=\(databaseName)")
        PasswordStore.biometricPassword(
            databaseName: databaseName,
            accessGroup: accessGroup
        ) { [weak self] password in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == requestID else { return }
                self.biometricUnlockInProgress = false
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                Log.info(
                    "autofill",
                    "macOS credential provider Touch ID unlock finished: success=\(password != nil) ms=\(elapsedMilliseconds)")
                guard let password else { return }
                self.unlock(
                    password: password,
                    databaseName: databaseName,
                    showsPasswordError: false)
            }
        }
    }

    private func unlock(password: String, databaseName: String, showsPasswordError: Bool) {
        guard let snapshotRoot = Self.snapshotRoot,
              Self.currentDatabaseName(in: snapshotRoot) == databaseName else {
            stage = .noVault
            Log.warn("autofill", "macOS credential provider snapshot unavailable or changed")
            return
        }

        let store = DatabaseStore(root: snapshotRoot)
        do {
            let database = try store.loadUnlocked(name: databaseName, password: password).0
            cards = database.activeCards.filter { card in
                guard card.autofillEnabled,
                      !card.login.isEmpty,
                      !card.password.isEmpty,
                      card.fields.contains(where: { $0.type == .website && !$0.value.isEmpty }) else {
                    return false
                }
                if let requestedRecordIdentifier,
                   requestedRecordIdentifier != card.id.uuidString { return false }
                guard !serviceIdentifiers.isEmpty else { return true }
                let websiteFields = card.fields.filter { $0.type == .website }
                return serviceIdentifiers.contains { SiteMatching.matches($0, sites: websiteFields) }
            }
            stage = .unlocked
            showUnlockError = false
            masterInput = ""
            Log.info("autofill", "macOS credential provider unlocked: candidates=\(cards.count)")
            if (!serviceIdentifiers.isEmpty || requestedRecordIdentifier != nil),
               cards.count == 1, let card = cards.first {
                select(card)
            }
        } catch {
            showUnlockError = showsPasswordError
            Log.warn("autofill", "macOS credential provider unlock failed: \(error)")
        }
    }

    private func updateBiometricUnlockAvailability() {
        guard let accessGroup = Self.keychainAccessGroup,
              let snapshotRoot = Self.snapshotRoot,
              let databaseName = Self.currentDatabaseName(in: snapshotRoot) else { return }
        biometricUnlockAvailable = PasswordStore.biometricAvailable()
            && PasswordStore.hasBiometricItem(
                databaseName: databaseName,
                accessGroup: accessGroup)
    }

    /// Returns a selected password to the system.
    func select(_ card: Card) {
        guard !card.login.isEmpty, !card.password.isEmpty else {
            Log.warn("autofill", "macOS credential provider rejected empty credential")
            return
        }
        let credential = ASPasswordCredential(user: card.login, password: card.password)
        context?.completeRequest(withSelectedCredential: credential, completionHandler: nil)
        Log.info("autofill", "macOS credential provided: card=\(card.id.uuidString.prefix(8))")
    }

    /// Cancels the active system request.
    func cancel() {
        let error = NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userCanceled.rawValue)
        context?.cancelRequest(withError: error)
    }

    private static var snapshotRoot: URL? {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return group.appendingPathComponent(snapshotDirectory, isDirectory: true)
    }

    private static func currentDatabaseName(in root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("current")),
              let name = String(data: data, encoding: .utf8),
              !name.isEmpty else { return nil }
        return name
    }

    private static func normalizedServiceURL(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else { return nil }
        return components.string
    }
}
