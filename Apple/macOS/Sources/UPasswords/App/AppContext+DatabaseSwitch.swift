import AppKit
import CryptoKit

import UPasswordsCore
import UPasswordsPersistence

/// 切换密码库:先验证目标库解锁密码,成功才切换。
extension AppContext {

    /// Creates a local vault directly in the SwiftData store.
    func createManagedDatabase(name: String, password: String) throws {
        guard let nativeStore else {
            throw DatabaseStore.StoreError(L10n.t("sync_error"))
        }
        try ensureDatabaseNameAvailable(name)
        try nativeStore.createVault(name: name, password: password)
        if dbsInfo().count == 1 { store.mainDatabaseName = name }
    }

    /// Checks SwiftData and unmigrated legacy files so old stores remain discoverable.
    func databaseExists(_ name: String) -> Bool {
        if let nativeStore, (try? nativeStore.containsVault(name: name)) == true { return true }
        return store.exists(name)
    }

    /// Fails closed if either catalog cannot prove the destination name is unused.
    func ensureDatabaseNameAvailable(_ name: String) throws {
        guard let nativeStore else {
            throw DatabaseStore.StoreError(L10n.t("sync_error"))
        }
        guard try !nativeStore.containsVault(name: name), !store.exists(name) else {
            throw DatabaseStore.StoreError(L10n.t("database_already_exists_error"))
        }
    }

    /// Migrates a legacy file store on first access and returns the SwiftData store.
    func managedStoreForVault(name: String, password: String) throws -> SwiftDataVaultStore {
        guard let nativeStore else {
            throw DatabaseStore.StoreError(L10n.t("sync_error"))
        }
        if try nativeStore.containsVault(name: name) {
            try nativeStore.migrateLegacyMetadataIfNeeded(name: name, password: password, legacyStore: store)
        } else {
            _ = try nativeStore.importLegacyIfNeeded(name: name, password: password, legacyStore: store)
        }
        return nativeStore
    }

    /// Deletes a vault from SwiftData and removes any remaining legacy sidecars.
    func deleteManagedDatabase(name: String) throws {
        guard let nativeStore else {
            throw DatabaseStore.StoreError(L10n.t("sync_error"))
        }
        let wasMain = store.mainDatabaseName == name
        try nativeStore.deleteVault(name: name)
        try store.delete(name: name)
        if wasMain {
            store.mainDatabaseName = dbsInfo().first?.name ?? "Main"
        }
    }

    /// Refreshes the encrypted snapshot consumed by the Safari and credential-provider extensions.
    func pushExtensionSnapshot(database: PasswordDatabase, name: String, vaultKey: SymmetricKey) {
        guard let nativeStore else { return }
        do {
            let envelope = try nativeStore.envelopeData(vaultName: name)
            let body = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            SafariSnapshotBridge.push(databaseName: name, encryptedBody: body, envelope: envelope)
        } catch {
            Log.error("autofill", "extension snapshot generation failed for \(name): \(error)")
        }
    }

    /// Renames the SwiftData vault and associated backup metadata.
    ///
    /// - Parameters:
    ///   - oldName: 当前本地密码库名。
    ///   - newName: 新的本地密码库名。
    /// - Throws: 名称校验或 local persistence errors.
    func renameDatabase(from oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        guard let nativeStore else {
            throw DatabaseStore.StoreError(L10n.t("sync_error"))
        }
        try ensureDatabaseNameAvailable(newName)
        if try nativeStore.containsVault(name: oldName) {
            try nativeStore.renameVault(from: oldName, to: newName)
            do {
                try store.rename(oldName, to: newName, allowMissingDatabase: true)
            } catch {
                do {
                    try nativeStore.renameVault(from: newName, to: oldName)
                } catch {
                    Log.error("db", "SwiftData rename rollback failed: \(error)")
                }
                throw error
            }
        } else {
            try store.rename(oldName, to: newName)
        }
    }

    /// Loads a reviewed source snapshot after migrating any legacy file store.
    func loadCardImportSource(
        name: String,
        password: String,
        matching fingerprint: Data? = nil
    ) throws -> CrossDatabaseCardImporter.SourceSnapshot {
        let nativeStore = try managedStoreForVault(name: name, password: password)
        return try nativeStore.loadCardImportSource(
            name: name,
            password: password,
            matching: fingerprint
        )
    }

    /// 弹窗要求输入目标库的解锁密码,验证通过后直接切换并解锁;
    /// 取消或失败则留在当前会话(密码错误可原地重试)。
    /// 供「管理密码库」弹窗与菜单栏「切换密码库」共用。
    /// - Parameter name: 目标库名
    /// - Returns: 是否切换成功
    @discardableResult
    func promptUnlockAndSwitch(to name: String) -> Bool {
        guard name != databaseName || phase == .locked else { return true }
        let alert = NSAlert()
        alert.messageText = String(format: L10n.t("switch_database_unlock_title"), name)
        alert.informativeText = L10n.t("switch_database_unlock_message")
        alert.addButton(withTitle: L10n.t("unlock_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else {
                Log.info("db", "switch to \"\(name)\" cancelled at password prompt")
                return false
            }
            do {
                try unlock(name: name, password: input.stringValue)
                store.mainDatabaseName = name
                activeSheet = nil
                Log.info("db", "switched to \"\(name)\" after password verify")
                return true
            } catch {
                Log.warn("db", "switch to \"\(name)\" failed: wrong password")
                alert.informativeText = L10n.t("wrong_password_error")
                input.stringValue = ""
            }
        }
    }
}

extension AppContext {
    /// 请求旧主密码以验证并保护本机副本，再接管已用新密码加密的云端库。
    func promptPreviousPasswordForRekey(newPassword: String) async {
        let alert = NSAlert()
        alert.messageText = L10n.t("sync_previous_password_title")
        alert.informativeText = L10n.t("sync_previous_password_message")
        alert.addButton(withTitle: L10n.t("unlock_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            guard !input.stringValue.isEmpty else {
                alert.informativeText = L10n.t("sync_previous_password_error")
                continue
            }
            switch await adoptRemotePassword(newPassword, previousPassword: input.stringValue) {
            case .success:
                AppToast.shared.show(L10n.t("last_sync_completed_prompt"))
                return
            case .wrongPreviousPassword:
                alert.informativeText = L10n.t("sync_previous_password_error")
                input.stringValue = ""
            case .wrongPassword:
                AppToast.shared.show(L10n.t("sync_adopt_failed_hint"))
                return
            case .previousPasswordRequired, .protectedData:
                return
            }
        }
        Log.info("sync", "previous password prompt cancelled")
    }

    /// 远端被「其他设备改后的新密码」加密时的接管弹窗:输入新密码 →
    /// 合并+换密+重传。
    /// 若密码反复不对,多半是局面反转(本机才是改密方,云端还是旧密码),
    /// 对话框同时提供「用本地数据覆盖云端」逃生口。
    func promptAdoptRemotePassword() {
        let alert = NSAlert()
        alert.messageText = L10n.t("ios_sync_adopt_password_title")
        alert.informativeText = L10n.t("ios_sync_adopt_password_message")
        alert.addButton(withTitle: L10n.t("unlock_button"))
        alert.addButton(withTitle: L10n.t("ios_sync_overwrite_cloud_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        if choice == .alertSecondButtonReturn {
            // 局面反转:本机是改密方,云端是旧密码 → 以本机为准覆盖
            Log.info("sync", "adopt prompt → user chose overwrite with local")
            promptOverwriteUnreadableRemote()
            return
        }
        guard choice == .alertFirstButtonReturn, !input.stringValue.isEmpty else {
            Log.info("sync", "adopt remote password cancelled at prompt")
            return
        }
        let pw = input.stringValue
        Task {
            let result = await adoptRemotePassword(pw)
            if result == .success {
                AppToast.shared.show(L10n.t("last_sync_completed_prompt"))
            } else if result == .wrongPassword {
                AppToast.shared.show(L10n.t("sync_adopt_failed_hint"))
            }
        }
    }

    /// 「用本地数据覆盖云端」的确认弹窗(丢弃远端内容,须用户明确确认)。
    func promptOverwriteUnreadableRemote() {
        let alert = NSAlert()
        alert.messageText = L10n.t("ios_sync_overwrite_cloud_button")
        alert.informativeText = L10n.t("ios_sync_overwrite_cloud_query")
        alert.addButton(withTitle: L10n.t("ok_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await overwriteUnreadableRemote() }
    }
}
