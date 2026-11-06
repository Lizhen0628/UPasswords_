import Foundation

import UPasswordsCore
import UPasswordsPersistence

extension AppContext {
    /// 重新验证来源快照后，将所选卡片作为新记录导入目标密码库。
    /// - Parameters:
    ///   - sourceName: 存放待导入卡片的本地密码库名。
    ///   - sourcePassword: 来源密码库的主密码。
    ///   - sourceFingerprint: 审核界面展示的加密数据指纹。
    ///   - destinationName: 审核界面中的目标密码库名。
    ///   - selectedCardIDs: 用户选中的来源卡片标识。
    /// - Returns: 导入摘要及已提交的目标库快照。
    /// - Throws: 来源校验、目标库状态、选择项或原子提交失败时抛出错误。
    func importCards(
        from sourceName: String,
        sourcePassword: String,
        sourceFingerprint: Data,
        into destinationName: String,
        selecting selectedCardIDs: Set<UUID>
    ) throws -> CrossDatabaseCardImporter.Plan {
        guard destinationName == databaseName else {
            throw CrossDatabaseCardImporter.ImportError.destinationChanged
        }
        guard sourceName != databaseName else {
            throw CrossDatabaseCardImporter.ImportError.sameDatabase
        }
        guard phase == .unlocked, let vaultKey else {
            throw CrossDatabaseCardImporter.ImportError.destinationUnavailable
        }
        guard syncState != .syncing else {
            throw CrossDatabaseCardImporter.ImportError.destinationSyncing
        }

        let startedAt = Date()
        Log.info("db", "card import started source=\"\(sourceName)\" destination=\"\(databaseName)\" selected=\(selectedCardIDs.count)")
        let source = try loadCardImportSource(
            name: sourceName, password: sourcePassword, matching: sourceFingerprint)
        let plan = try CrossDatabaseCardImporter.makePlan(
            from: source,
            into: database,
            syncState: rowSync,
            selecting: selectedCardIDs)
        guard !plan.importedCardIDs.isEmpty else { return plan }

        try commitSyncSnapshot(plan.database, name: databaseName, vaultKey: vaultKey, state: plan.syncState)
        database = plan.database
        rowSync = plan.syncState
        selectedCardId = plan.importedCardIDs.first
        lastActivity = Date()
        pushExtensionSnapshot(database: database, name: databaseName, vaultKey: vaultKey)
        Log.info(
            "db",
            "imported cards from \"\(sourceName)\" into \"\(databaseName)\" count=\(plan.importedCardIDs.count) labels=\(plan.createdLabelCount) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")

        if relayBound {
            Task { [weak self] in await self?.sync(auto: true) }
        }
        return plan
    }
}
