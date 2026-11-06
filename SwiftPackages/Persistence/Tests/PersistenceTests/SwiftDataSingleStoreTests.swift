import Foundation
import Testing

import UPasswordsCore
@testable import UPasswordsPersistence

@Suite("SwiftData single-store persistence")
struct SwiftDataSingleStoreTests {
    @Test("A native vault persists data and sync state without a legacy body")
    func nativeVaultRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-native-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = DatabaseStore(root: root)
        let native = try SwiftDataVaultStore(root: root)
        let key = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(key, password: "test-password")
        var database = PasswordDatabase()
        database.cards = [Card(title: "Saved card")]
        var state = RowSyncState()
        state.cursor = 42
        try native.replace(
            database,
            name: "Vault",
            envelope: envelope,
            vaultKey: key,
            syncState: state,
            attachmentDownloadLedger: AttachmentDownloadLedger()
        )
        #expect(!legacy.exists("Vault"))
        #expect(try native.loadUnlocked(name: "Vault", password: "test-password").0.cards.first?.title == "Saved card")
        #expect(try native.loadSyncState(vaultName: "Vault")?.cursor == 42)
        let snapshot = try native.loadCardImportSource(name: "Vault", password: "test-password")
        _ = try native.loadCardImportSource(name: "Vault", password: "test-password", matching: snapshot.fingerprint)
        try native.renameVault(from: "Vault", to: "Renamed")
        #expect(try native.listVaults().map(\.name) == ["Renamed"])
        try native.deleteVault(name: "Renamed")
        #expect(try native.listVaults().isEmpty)
    }

    @Test("Metadata from a dual-written vault is migrated before SwiftData becomes authoritative")
    func migrateLegacyMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = DatabaseStore(root: root)
        let native = try SwiftDataVaultStore(root: root)
        let key = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(key, password: "test-password")
        let database = PasswordDatabase()
        var state = RowSyncState()
        state.cursor = 73
        try legacy.commitSyncSnapshot(database, name: "Vault", vaultKey: key, state: state, envelope: envelope)
        try native.replace(database, name: "Vault", envelope: envelope, vaultKey: key)
        try native.migrateLegacyMetadataIfNeeded(name: "Vault", password: "test-password", legacyStore: legacy)
        #expect(try native.loadSyncState(vaultName: "Vault")?.cursor == 73)
        #expect(legacy.exists("Vault"))
        state.cursor = 99
        try native.saveSyncState(state, vaultName: "Vault")
        try native.migrateLegacyMetadataIfNeeded(name: "Vault", password: "test-password", legacyStore: legacy)
        #expect(try native.loadSyncState(vaultName: "Vault")?.cursor == 99)
    }

    @Test("Native backup restore and history survive key rotation and failed writes")
    func backupRestoreAndKeyRotation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-native-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = DatabaseStore(root: root)
        let native = try SwiftDataVaultStore(root: root)
        let sourceKey = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(sourceKey, password: "source-password")
        var database = PasswordDatabase()
        database.cards = [Card(title: "Backup card")]
        try native.replace(database, name: "Source", envelope: envelope, vaultKey: sourceKey)
        let captured = try await BackupPackage.capture(
            store: legacy, name: "Source", database: database, vaultKey: sourceKey,
            syncState: RowSyncState(), envelope: envelope)
        let assessment = try BackupPackage.assess(at: captured.url, sourcePassword: "source-password")
        let restored = try legacy.restoreBackupSnapshot(
            backup: captured.url, sourcePassword: "source-password", newPassword: "restored-password",
            expectedPackageVerificationToken: assessment.verificationToken,
            allowIncompletePackage: true)
        try native.replace(
            restored.database, name: "Restored", envelope: restored.envelope, vaultKey: restored.vaultKey,
            syncState: restored.syncState, attachmentDownloadLedger: restored.attachmentDownloadLedger,
            backupHistory: restored.backupHistory)
        #expect(!legacy.exists("Source"))
        #expect(!legacy.exists("Restored"))
        #expect(try native.loadBackupHistory(vaultName: "Restored", vaultKey: restored.vaultKey) != nil)

        let rotatedKey = DatabaseCipher.generateVaultKey()
        let rotatedEnvelope = try DatabaseCipher.wrapVaultKey(rotatedKey, password: "rotated-password")
        #expect(throws: (any Error).self) {
            try native.replace(
                restored.database, name: "Restored", envelope: rotatedEnvelope, vaultKey: rotatedKey,
                previousVaultKey: DatabaseCipher.generateVaultKey())
        }
        #expect(try native.loadUnlocked(name: "Restored", password: "restored-password").0.cards.first?.title
            == "Backup card")
        #expect(try native.loadBackupHistory(vaultName: "Restored", vaultKey: restored.vaultKey) != nil)

        try native.replace(
            restored.database, name: "Restored", envelope: rotatedEnvelope, vaultKey: rotatedKey,
            previousVaultKey: restored.vaultKey)
        #expect(try native.loadUnlocked(name: "Restored", password: "rotated-password").0.cards.first?.title
            == "Backup card")
        #expect(try native.loadBackupHistory(vaultName: "Restored", vaultKey: rotatedKey) != nil)
        #expect(throws: (any Error).self) {
            try native.loadBackupHistory(vaultName: "Restored", vaultKey: restored.vaultKey)
        }
    }
}
