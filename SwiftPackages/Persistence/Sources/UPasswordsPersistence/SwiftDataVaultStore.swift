import CryptoKit
import Foundation
import SwiftData

import UPasswordsCore

/// A local encrypted vault row. The field names intentionally mirror the
/// cloud business table; `body` remains client-side ciphertext.
@Model
public final class LocalVaultRecord {
    @Attribute(.unique) public var vaultID: String
    @Attribute(.unique) public var name: String
    public var passwordVersion: Int64
    public var passwordChangedMS: Int64
    public var envelopeEnc: Data
    public var createdMS: Int64
    public var updatedMS: Int64
    public var syncStateData: Data?
    public var attachmentDownloadLedgerData: Data?
    public var backupHistoryData: Data?

    public init(
        vaultID: String,
        name: String,
        passwordVersion: Int64 = 1,
        passwordChangedMS: Int64,
        envelopeEnc: Data,
        createdMS: Int64,
        updatedMS: Int64,
        syncStateData: Data? = nil,
        attachmentDownloadLedgerData: Data? = nil,
        backupHistoryData: Data? = nil
    ) {
        self.vaultID = vaultID
        self.name = name
        self.passwordVersion = passwordVersion
        self.passwordChangedMS = passwordChangedMS
        self.envelopeEnc = envelopeEnc
        self.createdMS = createdMS
        self.updatedMS = updatedMS
        self.syncStateData = syncStateData
        self.attachmentDownloadLedgerData = attachmentDownloadLedgerData
        self.backupHistoryData = backupHistoryData
    }
}

/// Encrypted card or label row matching the cloud `vault_items` business table.
@Model
public final class LocalVaultItemRecord {
    @Attribute(.unique) public var rowKey: String
    public var vaultID: String
    public var itemUUID: String
    public var kind: Int16
    public var revision: Int64
    public var body: Data
    public var bodySHA256: String
    public var bodyBytes: Int64
    public var modifiedMS: Int64
    public var createdMS: Int64
    public var updatedMS: Int64
    public var originSessionID: String?
    public var originDeviceName: String
    public var originPlatform: String

    public init(
        vaultID: String,
        itemUUID: String,
        kind: Int16,
        revision: Int64,
        body: Data,
        bodySHA256: String,
        bodyBytes: Int64,
        modifiedMS: Int64,
        createdMS: Int64,
        updatedMS: Int64,
        originSessionID: String? = nil,
        originDeviceName: String = "",
        originPlatform: String = "other"
    ) {
        self.rowKey = "\(vaultID):\(itemUUID.lowercased())"
        self.vaultID = vaultID
        self.itemUUID = itemUUID.lowercased()
        self.kind = kind
        self.revision = revision
        self.body = body
        self.bodySHA256 = bodySHA256
        self.bodyBytes = bodyBytes
        self.modifiedMS = modifiedMS
        self.createdMS = createdMS
        self.updatedMS = updatedMS
        self.originSessionID = originSessionID
        self.originDeviceName = originDeviceName
        self.originPlatform = originPlatform
    }
}

/// Local copy of the cloud attachment metadata table. Attachment bytes are
/// stored separately as encrypted cache records, so metadata survives cache
/// eviction and can still participate in version comparison.
@Model
public final class LocalAttachmentRecord {
    @Attribute(.unique) public var attachmentKey: String
    public var vaultID: String
    public var attachUUID: String
    public var cardUUID: String
    public var contentVersion: String
    public var objectKey: String
    public var dekWrapped: Data
    public var sha256: String
    public var bytes: Int64
    public var createdMS: Int64
    public var retiredMS: Int64?
    public var unreferencedMS: Int64?
    public var purgeStartedMS: Int64?

    public init(
        vaultID: String,
        attachUUID: String,
        cardUUID: String,
        contentVersion: String,
        objectKey: String = "",
        dekWrapped: Data = Data(),
        sha256: String,
        bytes: Int64,
        createdMS: Int64,
        retiredMS: Int64? = nil,
        unreferencedMS: Int64? = nil,
        purgeStartedMS: Int64? = nil
    ) {
        self.attachmentKey = "\(vaultID):\(attachUUID.lowercased()):\(contentVersion.lowercased())"
        self.vaultID = vaultID
        self.attachUUID = attachUUID.lowercased()
        self.cardUUID = cardUUID.lowercased()
        self.contentVersion = contentVersion.lowercased()
        self.objectKey = objectKey
        self.dekWrapped = dekWrapped
        self.sha256 = sha256
        self.bytes = bytes
        self.createdMS = createdMS
        self.retiredMS = retiredMS
        self.unreferencedMS = unreferencedMS
        self.purgeStartedMS = purgeStartedMS
    }
}

/// Encrypted local attachment bytes. It is intentionally not part of the
/// shared cloud business schema because it is a device cache.
@Model
public final class LocalAttachmentContentRecord {
    @Attribute(.unique) public var contentKey: String
    public var vaultID: String
    public var attachUUID: String
    public var contentVersion: String
    public var cipher: Data
    public var updatedMS: Int64

    public init(
        vaultID: String,
        attachUUID: String,
        contentVersion: String,
        cipher: Data,
        updatedMS: Int64
    ) {
        self.contentKey = "\(vaultID):\(attachUUID.lowercased()):\(contentVersion.lowercased())"
        self.vaultID = vaultID
        self.attachUUID = attachUUID.lowercased()
        self.contentVersion = contentVersion.lowercased()
        self.cipher = cipher
        self.updatedMS = updatedMS
    }
}

/// SwiftData-backed native store used by macOS, iOS, and the App Group.
/// Every business payload is encrypted before it reaches SQLite.
public final class SwiftDataVaultStore {
    public let container: ModelContainer
    private let context: ModelContext

    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            "UPasswordsNativeVault",
            schema: Schema([
                LocalVaultRecord.self,
                LocalVaultItemRecord.self,
                LocalVaultProfileRecord.self,
                LocalAttachmentRecord.self,
                LocalAttachmentContentRecord.self
            ]),
            url: root.appendingPathComponent("UPasswordsNativeVault.store"),
            cloudKitDatabase: .none
        )
        container = try ModelContainer(
            for: LocalVaultRecord.self,
            LocalVaultItemRecord.self,
            LocalVaultProfileRecord.self,
            LocalAttachmentRecord.self,
            LocalAttachmentContentRecord.self,
            configurations: configuration
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
        try migrateProfileRows()
    }

    /// Returns whether a migrated local vault exists without attempting to unlock it.
    public func containsVault(name: String) throws -> Bool {
        try fetchVault(name: name) != nil
    }

    /// Returns vault metadata without decrypting business rows.
    public func listVaults() throws -> [LocalVaultRecord] {
        try context.fetch(FetchDescriptor<LocalVaultRecord>()).sorted { $0.name < $1.name }
    }

    /// Creates an encrypted vault directly in SwiftData.
    public func createVault(name: String, password: String, now: Date = Date()) throws {
        guard name.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw DatabaseStore.StoreError(L10n.t("database_name_error"))
        }
        guard try fetchVault(name: name) == nil else {
            throw DatabaseStore.StoreError(L10n.t("database_already_exists_error"))
        }
        let database = PasswordDatabase.createDefault(now: now)
        let vaultKey = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(vaultKey, password: password)
        try replace(
            database,
            name: name,
            envelope: envelope,
            vaultKey: vaultKey,
            syncState: RowSyncState(),
            attachmentDownloadLedger: AttachmentDownloadLedger()
        )
        PasswordStore.savePassword(password, databaseName: name)
        Log.info("db", "created SwiftData vault \"\(name)\"")
    }

    /// Restores an encrypted body/envelope pair directly into SwiftData.
    public func restoreVaultFromFiles(
        bodyURL: URL,
        envelopeURL: URL,
        name: String,
        password: String
    ) throws {
        guard name.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw DatabaseStore.StoreError(L10n.t("database_name_error"))
        }
        guard try fetchVault(name: name) == nil else {
            throw DatabaseStore.StoreError(L10n.t("database_already_exists_error"))
        }

        let body: Data
        let envelope: Data
        do {
            body = try Data(contentsOf: bodyURL)
            envelope = try Data(contentsOf: envelopeURL)
        } catch {
            Log.error("db", "restore from local files unreadable (\(bodyURL.lastPathComponent)): \(error)")
            throw DatabaseStore.StoreError(L10n.t("local_files_unreadable_error"))
        }
        guard DatabaseCipher.isV2Container(body) else {
            throw DatabaseCipher.CipherError(message: L10n.t("wrong_database_format_error"))
        }
        guard DatabaseCipher.envelopeChangedAt(envelope) != nil else {
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        let vaultKey = try DatabaseCipher.unwrapVaultKey(envelope, password: password)
        let database = try PasswordDatabase.parse(DatabaseCipher.decryptBody(body, vaultKey: vaultKey))
        try replace(
            database,
            name: name,
            envelope: envelope,
            vaultKey: vaultKey,
            syncState: RowSyncState(),
            attachmentDownloadLedger: AttachmentDownloadLedger()
        )
        PasswordStore.savePassword(password, databaseName: name)
        Log.info("db", "restored SwiftData vault \"\(name)\" from local files cards=\(database.cards.count)")
    }

    /// Returns an encrypted password envelope for a vault.
    public func envelopeData(vaultName: String) throws -> Data {
        guard let vault = try fetchVault(name: vaultName) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        return vault.envelopeEnc
    }

    /// Loads retained backup history authenticated by the current vault key.
    public func loadBackupHistory(
        vaultName: String,
        vaultKey: SymmetricKey
    ) throws -> BackupPackage.RestoredHistory? {
        guard let sealedHistory = try fetchVault(name: vaultName)?.backupHistoryData else { return nil }
        return try BackupPackage.openRestoredHistory(sealedHistory, vaultKey: vaultKey)
    }

    /// Returns durable row-sync state, or nil when the vault predates its SwiftData state.
    public func loadSyncState(vaultName: String) throws -> RowSyncState? {
        guard let data = try fetchVault(name: vaultName)?.syncStateData else { return nil }
        return try JSONDecoder().decode(RowSyncState.self, from: data)
    }

    /// Persists row-sync state in the SwiftData vault record.
    public func saveSyncState(_ state: RowSyncState, vaultName: String) throws {
        guard let vault = try fetchVault(name: vaultName) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        vault.syncStateData = try JSONEncoder().encode(state)
        vault.updatedMS = Int64(Date().timeIntervalSince1970 * 1000)
        try context.save()
    }

    /// Loads local attachment retry and retention policy for a vault.
    public func loadAttachmentDownloadLedger(vaultName: String) throws -> AttachmentDownloadLedger {
        guard let data = try fetchVault(name: vaultName)?.attachmentDownloadLedgerData else {
            return AttachmentDownloadLedger()
        }
        return try JSONDecoder().decode(AttachmentDownloadLedger.self, from: data)
    }

    /// Authenticates a source vault and returns a stable fingerprint of its encrypted rows.
    public func loadCardImportSource(
        name: String,
        password: String,
        matching fingerprint: Data? = nil
    ) throws -> CrossDatabaseCardImporter.SourceSnapshot {
        let startedAt = Date()
        Log.info("db", "card import source verification started for \"\(name)\"")
        do {
            let (database, _) = try loadUnlocked(name: name, password: password, hydrateAttachments: false)
            guard let vault = try fetchVault(name: name) else {
                throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
            }
            let itemRows = try fetchItems(vaultID: vault.vaultID).sorted { $0.rowKey < $1.rowKey }
            let profileRows = try fetchProfiles(vaultID: vault.vaultID).sorted { $0.rowKey < $1.rowKey }
            var fingerprintInput = Data()
            for row in itemRows {
                fingerprintInput.append(contentsOf: row.rowKey.utf8)
                fingerprintInput.append(0)
                fingerprintInput.append(contentsOf: row.bodySHA256.utf8)
                fingerprintInput.append(0)
            }
            for row in profileRows {
                fingerprintInput.append(contentsOf: row.rowKey.utf8)
                fingerprintInput.append(0)
                fingerprintInput.append(contentsOf: row.bodySHA256.utf8)
                fingerprintInput.append(0)
            }
            let actualFingerprint = Data(SHA256.hash(data: fingerprintInput))
            if let fingerprint, fingerprint != actualFingerprint {
                throw CrossDatabaseCardImporter.ImportError.selectionChanged
            }
            Log.info(
                "db",
                "card import source verified for \"\(name)\" cards=\(database.cards.count) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            return CrossDatabaseCardImporter.SourceSnapshot(
                database: database,
                fingerprint: actualFingerprint
            )
        } catch {
            Log.error("db", "card import source verification failed for \"\(name)\": \(error)")
            throw error
        }
    }

    /// Persists local attachment retry and retention policy in SwiftData.
    public func saveAttachmentDownloadLedger(
        _ ledger: AttachmentDownloadLedger,
        vaultName: String
    ) throws {
        guard let vault = try fetchVault(name: vaultName) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        vault.attachmentDownloadLedgerData = try JSONEncoder().encode(ledger)
        vault.updatedMS = Int64(Date().timeIntervalSince1970 * 1000)
        try context.save()
    }

    /// Estimates the persisted bytes for one vault, including encrypted attachment cache.
    public func estimatedStorageBytes(vaultName: String) throws -> Int64 {
        guard let vault = try fetchVault(name: vaultName) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        let itemBytes = try fetchItems(vaultID: vault.vaultID).reduce(Int64(0)) { $0 + $1.bodyBytes }
        let profileBytes = try fetchProfiles(vaultID: vault.vaultID).reduce(Int64(0)) { $0 + $1.bodyBytes }
        let attachmentBytes = try fetchContents(vaultID: vault.vaultID).reduce(Int64(0)) {
            $0 + Int64($1.cipher.count)
        }
        return Int64(vault.envelopeEnc.count) + itemBytes + profileBytes + attachmentBytes
    }

    /// Deletes one local vault and all of its business rows and attachment cache.
    ///
    /// This only removes the local SwiftData copy. The legacy file store and any
    /// cloud vault are owned by their callers and are not changed here.
    public func deleteVault(name: String) throws {
        guard let vault = try fetchVault(name: name) else { return }
        let vaultID = vault.vaultID
        try fetchItems(vaultID: vaultID).forEach(context.delete)
        try fetchProfiles(vaultID: vaultID).forEach(context.delete)
        try fetchAttachments(vaultID: vaultID).forEach(context.delete)
        try fetchContents(vaultID: vaultID).forEach(context.delete)
        context.delete(vault)
        try context.save()
        Log.info("db", "deleted SwiftData vault \"\(name)\"")
    }

    /// Deletes every local SwiftData vault, including orphaned migration rows.
    public func deleteAllVaults() throws {
        try context.fetch(FetchDescriptor<LocalVaultItemRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LocalVaultProfileRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LocalAttachmentRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LocalAttachmentContentRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<LocalVaultRecord>()).forEach(context.delete)
        try context.save()
        Log.info("db", "deleted all SwiftData vaults")
    }

    /// Renames a local vault without changing its encrypted business rows.
    public func renameVault(from oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        guard let vault = try fetchVault(name: oldName) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        guard try fetchVault(name: newName) == nil else {
            throw DatabaseStore.StoreError(L10n.t("database_already_exists_error"))
        }
        vault.name = newName
        try context.save()
        Log.info("db", "renamed SwiftData vault \"\(oldName)\" → \"\(newName)\"")
    }

    /// Removes cached ciphertext for an explicitly evicted attachment version.
    public func evictAttachmentContent(
        vaultName: String,
        attachmentID: UUID,
        contentVersion: UUID
    ) throws {
        guard let vault = try fetchVault(name: vaultName) else { return }
        let contentKey = "\(vault.vaultID):\(attachmentID.uuidString.lowercased()):\(contentVersion.uuidString.lowercased())"
        guard let content = try fetchContents(vaultID: vault.vaultID)
            .first(where: { $0.contentKey == contentKey }) else { return }
        context.delete(content)
        try context.save()
        Log.info("db", "evicted SwiftData attachment content id=\(attachmentID.uuidString.prefix(8))…")
    }

    /// Imports an existing encrypted `.upw` database exactly once.
    /// The legacy files are never removed; they remain the rollback source.
    @discardableResult
    public func importLegacyIfNeeded(
        name: String,
        password: String,
        legacyStore: DatabaseStore
    ) throws -> Bool {
        let existing = try fetchVault(name: name)
        guard existing == nil else { return false }
        let (database, key) = try legacyStore.loadUnlocked(name: name, password: password)
        let envelope = try Data(contentsOf: legacyStore.keyURL(for: name))
        let syncState = try legacyStore.loadSyncState(for: name)
        let attachmentLedger = try legacyStore.loadAttachmentDownloadLedger(for: name)
        let backupHistory = try legacyStore.loadBackupHistoryData(for: name)
        if let backupHistory { _ = try BackupPackage.openRestoredHistory(backupHistory, vaultKey: key) }
        try replace(
            database,
            name: name,
            envelope: envelope,
            vaultKey: key,
            passwordVersion: 1,
            syncState: syncState,
            attachmentDownloadLedger: attachmentLedger,
            backupHistory: backupHistory
        )
        Log.info("db", "imported legacy vault \"\(name)\" into SwiftData")
        return true
    }

    /// Migrates missing sidecar state from a previously dual-written vault after authentication.
    public func migrateLegacyMetadataIfNeeded(
        name: String,
        password: String,
        legacyStore: DatabaseStore
    ) throws {
        guard let vault = try fetchVault(name: name), legacyStore.exists(name),
              vault.syncStateData == nil || vault.attachmentDownloadLedgerData == nil else { return }
        let currentKey = try DatabaseCipher.unwrapVaultKey(vault.envelopeEnc, password: password)
        let (_, legacyKey) = try legacyStore.loadUnlocked(name: name, password: password)
        guard currentKey == legacyKey else {
            throw DatabaseStore.StoreError(L10n.t("sync_error"))
        }
        let state = vault.syncStateData == nil ? try legacyStore.loadSyncState(for: name) : nil
        let ledger = vault.attachmentDownloadLedgerData == nil
            ? try legacyStore.loadAttachmentDownloadLedger(for: name) : nil
        let history = vault.backupHistoryData == nil ? try legacyStore.loadBackupHistoryData(for: name) : nil
        if let history { _ = try BackupPackage.openRestoredHistory(history, vaultKey: currentKey) }
        if let state { vault.syncStateData = try JSONEncoder().encode(state) }
        if let ledger { vault.attachmentDownloadLedgerData = try JSONEncoder().encode(ledger) }
        if let history { vault.backupHistoryData = history }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        Log.info("db", "migrated legacy vault metadata for \"\(name)\"")
    }

    /// Loads and decrypts the local row tables using the supplied master password.
    public func loadUnlocked(
        name: String,
        password: String,
        hydrateAttachments: Bool = true
    ) throws -> (PasswordDatabase, SymmetricKey) {
        guard let vault = try fetchVault(name: name) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        let key = try DatabaseCipher.unwrapVaultKey(vault.envelopeEnc, password: password)
        let rows = try fetchItems(vaultID: vault.vaultID)
        let profileRows = try fetchProfiles(vaultID: vault.vaultID)
        var database = PasswordDatabase()
        let encryptedRows = rows.map { ($0.itemUUID, $0.kind, $0.body) }
            + profileRows.map { ($0.itemUUID, $0.kind, $0.body) }
        for (itemUUID, kind, body) in encryptedRows {
            guard let uuid = UUID(uuidString: itemUUID),
                  let plaintext = RowSyncCipher.decrypt(
                    body,
                    key: RowSyncKey(raw: key.withUnsafeBytes { Data($0) }),
                    uuid: uuid
                  ),
                  let item = DatabaseItemCodec.parse(
                    kind: UInt8(kind), uuid: uuid, data: plaintext
                  ) else {
                throw DatabaseStore.StoreError(L10n.t("database_corrupt_error"))
            }
            apply(item, to: &database)
        }
        if hydrateAttachments {
            try hydrateAttachmentContent(in: &database, vaultID: vault.vaultID, key: key)
        }
        return (database, key)
    }

    /// Returns cached attachment byte counts without loading their ciphertext into memory.
    public func cachedAttachmentBytes(
        vaultName: String
    ) throws -> [AttachmentDownloadLedger.Version: Int] {
        guard let vault = try fetchVault(name: vaultName) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        let contentKeys = try fetchCachedContentKeys(vaultID: vault.vaultID)
        var result: [AttachmentDownloadLedger.Version: Int] = [:]
        for attachment in try fetchAttachments(vaultID: vault.vaultID)
        where contentKeys.contains(attachment.attachmentKey) {
            guard let cardID = UUID(uuidString: attachment.cardUUID),
                  let attachmentID = UUID(uuidString: attachment.attachUUID),
                  let contentVersion = UUID(uuidString: attachment.contentVersion),
                  attachment.bytes >= 0, attachment.bytes <= Int64(Int.max) else { continue }
            let version = AttachmentDownloadLedger.Version(
                cardID: cardID,
                attachmentID: attachmentID,
                contentVersion: contentVersion
            )
            result[version] = Int(attachment.bytes)
        }
        return result
    }

    /// Decrypts one cached attachment version without hydrating other attachments.
    public func loadAttachmentContent(
        vaultName: String,
        cardID: UUID,
        attachmentID: UUID,
        contentVersion: UUID,
        vaultKey: SymmetricKey
    ) throws -> Data? {
        guard let vault = try fetchVault(name: vaultName) else {
            throw DatabaseStore.StoreError(L10n.t("database_not_found_error"))
        }
        let key = encryptedContentKey(
            vaultID: vault.vaultID,
            attachmentID: attachmentID,
            contentVersion: contentVersion
        )
        guard let record = try fetchAttachments(vaultID: vault.vaultID).first(where: {
            $0.attachmentKey == key
                && $0.cardUUID.caseInsensitiveCompare(cardID.uuidString) == .orderedSame
        }), let content = try fetchContent(contentKey: key) else { return nil }
        return try AttachmentSyncCipher.decrypt(
            cipher: content.cipher,
            dekWrapped: record.dekWrapped,
            key: RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) }),
            attachmentID: attachmentID,
            contentVersion: contentVersion
        )
    }

    /// Replaces one local vault in a single SwiftData transaction.
    public func replace(
        _ database: PasswordDatabase,
        name: String,
        vaultKey: SymmetricKey,
        passwordVersion: Int64? = nil,
        revisions: [UUID: UInt64] = [:],
        previousVaultKey: SymmetricKey? = nil,
        syncState: RowSyncState? = nil,
        attachmentDownloadLedger: AttachmentDownloadLedger? = nil,
        backupHistory: Data? = nil
    ) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let vaultID = (try fetchVault(name: name))?.vaultID ?? UUID().uuidString.lowercased()
        let envelope: Data
        if let current = try fetchVault(name: name) {
            envelope = current.envelopeEnc
        } else {
            throw DatabaseStore.StoreError(L10n.t("envelope_missing_error"))
        }
        try replace(
            database,
            name: name,
            vaultID: vaultID,
            envelope: envelope,
            vaultKey: vaultKey,
            passwordVersion: passwordVersion,
            revisions: revisions,
            previousVaultKey: previousVaultKey,
            syncState: syncState,
            attachmentDownloadLedger: attachmentDownloadLedger,
            backupHistory: backupHistory,
            now: now
        )
    }

    /// Creates or replaces the local record while retaining the encrypted envelope.
    public func replace(
        _ database: PasswordDatabase,
        name: String,
        envelope: Data,
        vaultKey: SymmetricKey,
        passwordVersion: Int64? = nil,
        revisions: [UUID: UInt64] = [:],
        previousVaultKey: SymmetricKey? = nil,
        syncState: RowSyncState? = nil,
        attachmentDownloadLedger: AttachmentDownloadLedger? = nil,
        backupHistory: Data? = nil
    ) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let vaultID = (try fetchVault(name: name))?.vaultID ?? UUID().uuidString.lowercased()
        try replace(
            database,
            name: name,
            vaultID: vaultID,
            envelope: envelope,
            vaultKey: vaultKey,
            passwordVersion: passwordVersion,
            revisions: revisions,
            previousVaultKey: previousVaultKey,
            syncState: syncState,
            attachmentDownloadLedger: attachmentDownloadLedger,
            backupHistory: backupHistory,
            now: now
        )
    }

    private func replace(
        _ database: PasswordDatabase,
        name: String,
        vaultID: String,
        envelope: Data,
        vaultKey: SymmetricKey,
        passwordVersion: Int64?,
        revisions: [UUID: UInt64],
        previousVaultKey: SymmetricKey?,
        syncState: RowSyncState?,
        attachmentDownloadLedger: AttachmentDownloadLedger?,
        backupHistory: Data?,
        now: Int64
    ) throws {
        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        let encodedSyncState = try syncState.map { try JSONEncoder().encode($0) }
        let encodedAttachmentDownloadLedger = try attachmentDownloadLedger.map {
            try JSONEncoder().encode($0)
        }
        let rowKey = RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) })
        try syncState?.validateQuarantinedItems(key: rowKey)
        let existingRows = try fetchItems(vaultID: vaultID)
        let rowsByKey = Dictionary(uniqueKeysWithValues: existingRows.map { ($0.rowKey, $0) })
        let existingProfiles = try fetchProfiles(vaultID: vaultID)
        let profilesByKey = Dictionary(uniqueKeysWithValues: existingProfiles.map { ($0.rowKey, $0) })
        let existingAttachments = try fetchAttachments(vaultID: vaultID)
        let attachmentsByKey = Dictionary(uniqueKeysWithValues: existingAttachments.map { ($0.attachmentKey, $0) })
        let existingContents = try fetchContents(vaultID: vaultID)
        let contentsByKey = Dictionary(uniqueKeysWithValues: existingContents.map { ($0.contentKey, $0) })
        let existingVault = try fetchVault(name: name)
        let vault = existingVault ?? LocalVaultRecord(
            vaultID: vaultID,
            name: name,
            passwordVersion: passwordVersion ?? 1,
            passwordChangedMS: now,
            envelopeEnc: envelope,
            createdMS: now,
            updatedMS: now
        )
        let envelopeChanged = vault.envelopeEnc != envelope
        vault.vaultID = vaultID
        vault.name = name
        vault.passwordVersion = passwordVersion ?? (envelopeChanged ? vault.passwordVersion + 1 : vault.passwordVersion)
        vault.envelopeEnc = envelope
        if envelopeChanged { vault.passwordChangedMS = now }
        vault.updatedMS = now
        if let encodedSyncState { vault.syncStateData = encodedSyncState }
        if let encodedAttachmentDownloadLedger {
            vault.attachmentDownloadLedgerData = encodedAttachmentDownloadLedger
        }
        if let backupHistory {
            vault.backupHistoryData = backupHistory
        } else if let previousVaultKey, previousVaultKey != vaultKey,
                  let existingHistory = existingVault?.backupHistoryData {
            vault.backupHistoryData = try BackupPackage.rekeyRestoredHistory(
                existingHistory,
                from: previousVaultKey,
                to: vaultKey
            )
        }
        if vault.modelContext == nil { context.insert(vault) }
        if let previousVaultKey, previousVaultKey != vaultKey {
            let oldKey = RowSyncKey(raw: previousVaultKey.withUnsafeBytes { Data($0) })
            for attachment in existingAttachments where !attachment.dekWrapped.isEmpty {
                guard let attachmentID = UUID(uuidString: attachment.attachUUID),
                      let version = UUID(uuidString: attachment.contentVersion) else {
                    throw DatabaseStore.StoreError(L10n.t("database_corrupt_error"))
                }
                attachment.dekWrapped = try AttachmentSyncCipher.rewrap(
                    attachment.dekWrapped,
                    oldKey: oldKey,
                    newKey: rowKey,
                    attachmentID: attachmentID,
                    contentVersion: version
                )
            }
        }
        var retainedRowKeys = Set<String>()
        var retainedProfileKeys = Set<String>()
        var activeAttachmentKeys = Set<String>()
        for item in RowSync.allItems(database: database) {
            let plaintext = DatabaseItemCodec.xmlData(item)
            let body = try RowSyncCipher.encrypt(plaintext, key: rowKey, uuid: item.uuid)
            let itemKey = "\(vaultID):\(item.uuid.uuidString.lowercased())"
            if case .userProfile = item {
                retainedProfileKeys.insert(itemKey)
                let prior = profilesByKey[itemKey]
                let revision = revisions[item.uuid].map(Int64.init) ?? max(1, prior?.revision ?? 1)
                let row = profilesByKey[itemKey] ?? LocalVaultProfileRecord(
                    vaultID: vaultID,
                    itemUUID: item.uuid.uuidString,
                    revision: revision,
                    body: body,
                    bodySHA256: SyncConflict.sha256Hex(body),
                    bodyBytes: Int64(body.count),
                    modifiedMS: Int64(item.modifiedMs),
                    createdMS: now,
                    updatedMS: now
                )
                row.revision = revision
                row.body = body
                row.bodySHA256 = SyncConflict.sha256Hex(body)
                row.bodyBytes = Int64(body.count)
                row.modifiedMS = Int64(item.modifiedMs)
                row.updatedMS = now
                if row.modelContext == nil { context.insert(row) }
            } else {
                retainedRowKeys.insert(itemKey)
                let prior = rowsByKey[itemKey]
                let revision = revisions[item.uuid].map(Int64.init) ?? max(1, prior?.revision ?? 1)
                let row = rowsByKey[itemKey] ?? LocalVaultItemRecord(
                    vaultID: vaultID,
                    itemUUID: item.uuid.uuidString,
                    kind: Int16(item.syncKind),
                    revision: revision,
                    body: body,
                    bodySHA256: SyncConflict.sha256Hex(body),
                    bodyBytes: Int64(body.count),
                    modifiedMS: Int64(item.modifiedMs),
                    createdMS: now,
                    updatedMS: now
                )
                row.kind = Int16(item.syncKind)
                row.revision = revision
                row.body = body
                row.bodySHA256 = SyncConflict.sha256Hex(body)
                row.bodyBytes = Int64(body.count)
                row.modifiedMS = Int64(item.modifiedMs)
                row.updatedMS = now
                if row.modelContext == nil { context.insert(row) }
            }
            try persistAttachments(
                from: item,
                vaultID: vaultID,
                key: rowKey,
                now: now,
                attachmentsByKey: attachmentsByKey,
                contentsByKey: contentsByKey,
                activeKeys: &activeAttachmentKeys
            )
        }
        for row in existingRows where !retainedRowKeys.contains(row.rowKey) { context.delete(row) }
        for row in existingProfiles where !retainedProfileKeys.contains(row.rowKey) { context.delete(row) }
        for attachment in existingAttachments where !activeAttachmentKeys.contains(attachment.attachmentKey) {
            if attachment.retiredMS == nil { attachment.retiredMS = now }
            if attachment.unreferencedMS == nil { attachment.unreferencedMS = now }
        }
        try context.save()
        committed = true
    }

    private func persistAttachments(
        from item: DatabaseItem,
        vaultID: String,
        key: RowSyncKey,
        now: Int64,
        attachmentsByKey: [String: LocalAttachmentRecord],
        contentsByKey: [String: LocalAttachmentContentRecord],
        activeKeys: inout Set<String>
    ) throws {
        guard case .card(let card) = item else { return }
        for attachment in card.images + card.files where attachment.hasPersistentID && attachment.hasPersistentContentVersion {
            let contentKey = encryptedContentKey(
                vaultID: vaultID,
                attachmentID: attachment.id,
                contentVersion: attachment.contentVersion
            )
            activeKeys.insert(contentKey)
            let encrypted: EncryptedAttachment?
            if let data = attachment.data {
                encrypted = try AttachmentSyncCipher.encrypt(
                    data: data,
                    key: key,
                    attachmentID: attachment.id,
                    contentVersion: attachment.contentVersion
                )
            } else {
                encrypted = nil
            }
            let record = attachmentsByKey[contentKey] ?? LocalAttachmentRecord(
                vaultID: vaultID,
                attachUUID: attachment.id.uuidString,
                cardUUID: card.id.uuidString,
                contentVersion: attachment.contentVersion.uuidString,
                dekWrapped: encrypted?.dekWrapped ?? Data(),
                sha256: encrypted.map { SyncConflict.sha256Hex($0.cipher) } ?? "",
                bytes: Int64(attachment.data?.count ?? 0),
                createdMS: now
            )
            record.cardUUID = card.id.uuidString.lowercased()
            if let encrypted {
                record.dekWrapped = encrypted.dekWrapped
                record.sha256 = SyncConflict.sha256Hex(encrypted.cipher)
                record.bytes = Int64(attachment.data?.count ?? 0)
                record.retiredMS = nil
                record.unreferencedMS = nil
                record.purgeStartedMS = nil
                let content = contentsByKey[contentKey] ?? LocalAttachmentContentRecord(
                    vaultID: vaultID,
                    attachUUID: attachment.id.uuidString,
                    contentVersion: attachment.contentVersion.uuidString,
                    cipher: encrypted.cipher,
                    updatedMS: now
                )
                content.cipher = encrypted.cipher
                content.updatedMS = now
                if content.modelContext == nil { context.insert(content) }
            }
            if record.modelContext == nil { context.insert(record) }
        }
    }

    private func encryptedContentKey(vaultID: String, attachmentID: UUID, contentVersion: UUID) -> String {
        "\(vaultID):\(attachmentID.uuidString.lowercased()):\(contentVersion.uuidString.lowercased())"
    }

    private func hydrateAttachmentContent(
        in database: inout PasswordDatabase,
        vaultID: String,
        key: SymmetricKey
    ) throws {
        let rowKey = RowSyncKey(raw: key.withUnsafeBytes { Data($0) })
        let records = try fetchAttachments(vaultID: vaultID)
        let contents = try fetchContents(vaultID: vaultID)
        let contentByKey = Dictionary(uniqueKeysWithValues: contents.map { ($0.contentKey, $0) })
        for cardIndex in database.cards.indices {
            for attachmentIndex in database.cards[cardIndex].images.indices {
                try hydrate(
                    &database.cards[cardIndex].images[attachmentIndex],
                    cardID: database.cards[cardIndex].id,
                    records: records,
                    contentByKey: contentByKey,
                    key: rowKey
                )
            }
            for attachmentIndex in database.cards[cardIndex].files.indices {
                try hydrate(
                    &database.cards[cardIndex].files[attachmentIndex],
                    cardID: database.cards[cardIndex].id,
                    records: records,
                    contentByKey: contentByKey,
                    key: rowKey
                )
            }
        }
    }

    private func hydrate(
        _ attachment: inout Attachment,
        cardID: UUID,
        records: [LocalAttachmentRecord],
        contentByKey: [String: LocalAttachmentContentRecord],
        key: RowSyncKey
    ) throws {
        guard let record = records.first(where: {
            $0.attachUUID.caseInsensitiveCompare(attachment.id.uuidString) == .orderedSame
                && $0.cardUUID.caseInsensitiveCompare(cardID.uuidString) == .orderedSame
                && $0.contentVersion.caseInsensitiveCompare(attachment.contentVersion.uuidString) == .orderedSame
        }), let content = contentByKey[record.attachmentKey] else { return }
        let data = try AttachmentSyncCipher.decrypt(
            cipher: content.cipher,
            dekWrapped: record.dekWrapped,
            key: key,
            attachmentID: attachment.id,
            contentVersion: attachment.contentVersion
        )
        _ = attachment.installDownloadedContent(data, for: attachment.contentVersion)
    }

    private func fetchVault(name: String) throws -> LocalVaultRecord? {
        try context.fetch(FetchDescriptor<LocalVaultRecord>(predicate: #Predicate { $0.name == name })).first
    }

    private func fetchItems(vaultID: String) throws -> [LocalVaultItemRecord] {
        try context.fetch(FetchDescriptor<LocalVaultItemRecord>(predicate: #Predicate { $0.vaultID == vaultID }))
    }

    private func fetchProfiles(vaultID: String) throws -> [LocalVaultProfileRecord] {
        try context.fetch(FetchDescriptor<LocalVaultProfileRecord>(predicate: #Predicate { $0.vaultID == vaultID }))
    }

    private func fetchCachedContentKeys(vaultID: String) throws -> Set<String> {
        var descriptor = FetchDescriptor<LocalAttachmentContentRecord>(
            predicate: #Predicate { $0.vaultID == vaultID }
        )
        descriptor.propertiesToFetch = [\.contentKey]
        return Set(try context.fetch(descriptor).map(\.contentKey))
    }

    private func fetchContent(contentKey: String) throws -> LocalAttachmentContentRecord? {
        try context.fetch(FetchDescriptor<LocalAttachmentContentRecord>(
            predicate: #Predicate { $0.contentKey == contentKey }
        )).first
    }

    private func migrateProfileRows() throws {
        let legacyRows = try context.fetch(FetchDescriptor<LocalVaultItemRecord>())
            .filter { $0.kind == 3 }
        guard !legacyRows.isEmpty else { return }

        let existingProfiles = try context.fetch(FetchDescriptor<LocalVaultProfileRecord>())
        let profilesByKey = Dictionary(uniqueKeysWithValues: existingProfiles.map { ($0.rowKey, $0) })
        for legacy in legacyRows {
            if profilesByKey[legacy.rowKey] == nil {
                context.insert(LocalVaultProfileRecord(
                    vaultID: legacy.vaultID,
                    itemUUID: legacy.itemUUID,
                    revision: legacy.revision,
                    body: legacy.body,
                    bodySHA256: legacy.bodySHA256,
                    bodyBytes: legacy.bodyBytes,
                    modifiedMS: legacy.modifiedMS,
                    createdMS: legacy.createdMS,
                    updatedMS: legacy.updatedMS,
                    originSessionID: legacy.originSessionID,
                    originDeviceName: legacy.originDeviceName,
                    originPlatform: legacy.originPlatform
                ))
            }
            context.delete(legacy)
        }
        try context.save()
        Log.info("db", "migrated \(legacyRows.count) profile rows to the dedicated SwiftData table")
    }

    private func fetchAttachments(vaultID: String) throws -> [LocalAttachmentRecord] {
        try context.fetch(FetchDescriptor<LocalAttachmentRecord>(predicate: #Predicate { $0.vaultID == vaultID }))
    }

    private func fetchContents(vaultID: String) throws -> [LocalAttachmentContentRecord] {
        try context.fetch(FetchDescriptor<LocalAttachmentContentRecord>(predicate: #Predicate { $0.vaultID == vaultID }))
    }

    private func apply(_ item: DatabaseItem, to database: inout PasswordDatabase) {
        switch item {
        case .card(let card): database.cards.append(card)
        case .label(let label): database.labels.append(label)
        case .userProfile(let profile): database.userProfiles.append(profile)
        }
    }
}
