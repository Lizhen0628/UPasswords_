import CryptoKit
import Foundation
import Network

import UPasswordsCore
import UPasswordsPersistence

extension AppContext {
    /// 监听网络策略变化；网络恢复时只重试可恢复的附件下载失败。
    func startAttachmentNetworkMonitor() {
        guard attachmentNetworkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasAvailable = self.attachmentNetworkState.isAvailable
                let hadObservation = self.attachmentNetworkObserved
                self.attachmentNetworkObserved = true
                let kind: AttachmentNetworkKind
                if path.usesInterfaceType(.wifi) {
                    kind = .wifi
                } else if path.usesInterfaceType(.wiredEthernet) {
                    kind = .wired
                } else if path.usesInterfaceType(.cellular) {
                    kind = .cellular
                } else {
                    kind = .unknown
                }
                self.attachmentNetworkState = AttachmentNetworkState(
                    isAvailable: path.status == .satisfied, kind: kind, isConstrained: path.isConstrained)
                if hadObservation, !wasAvailable, path.status == .satisfied, self.isAttachmentSessionUnlocked {
                    do {
                        try self.updateAttachmentLedger { $0.restartTransientFailures() }
                    } catch {
                        self.reportAttachmentLedgerError(error)
                    }
                }
                self.requeueCurrentDownloadIfDisallowed()
                self.scheduleMissingAttachmentDownloads()
            }
        }
        // NWPathMonitor 要求传入队列；指定主队列后，回调可安全使用主 actor 状态。
        monitor.start(queue: .main)
        attachmentNetworkMonitor = monitor
    }

    /// 根据当前附件引用和持久化版本策略重建待下载任务。
    func scheduleMissingAttachmentDownloads() {
        guard isAttachmentSessionUnlocked, !attachmentLedgerUnavailable else { return }
        do {
            let fingerprint = relay.token(database: databaseName).map { Data(SHA256.hash(data: Data($0.utf8))) }
            try updateAttachmentLedger {
                $0.reconcile(with: database)
                if let fingerprint { $0.resumeAfterAuthorization(fingerprint: fingerprint) }
            }
            for card in database.cards where hasMissingAttachmentContent(card) {
                enqueueAttachmentDownload(cardID: card.id, prioritized: false)
            }
            scheduleAttachmentRetry()
        } catch {
            reportAttachmentLedgerError(error)
        }
    }

    /// 打开卡片时恢复已淘汰附件的下载；只有用户明确重试才重置失败次数。
    func prioritizeAttachmentDownload(cardID: UUID, retryFailures: Bool = false) {
        guard isAttachmentSessionUnlocked else { return }
        do {
            let versions = AttachmentDownloadLedger.versions(in: database, cardID: cardID)
            let missingVersions = Set(database.card(id: cardID).map(missingRemoteAttachmentVersions(in:)) ?? [])
            try updateAttachmentLedger { ledger in
                for version in versions {
                    ledger.recordAccess(to: version)
                    if missingVersions.contains(version) {
                        ledger.request(version, resetFailures: retryFailures)
                    }
                }
            }
            enqueueAttachmentDownload(cardID: cardID, prioritized: true)
        } catch {
            reportAttachmentLedgerError(error)
        }
    }

    /// 只加载当前卡片已有的附件缓存，不触发其他文件的网络下载。
    func loadCachedAttachments(cardID: UUID) {
        guard phase == .unlocked, let vaultKey, let nativeStore,
              let cardIndex = database.cards.firstIndex(where: { $0.id == cardID }) else { return }
        let startedAt = Date()
        var updated = database
        var loadedCount = 0
        var loadedBytes = 0
        for attachmentIndex in updated.cards[cardIndex].images.indices {
            loadCachedAttachment(
                &updated.cards[cardIndex].images[attachmentIndex],
                cardID: cardID,
                vaultKey: vaultKey,
                store: nativeStore,
                loadedCount: &loadedCount,
                loadedBytes: &loadedBytes
            )
        }
        for attachmentIndex in updated.cards[cardIndex].files.indices {
            loadCachedAttachment(
                &updated.cards[cardIndex].files[attachmentIndex],
                cardID: cardID,
                vaultKey: vaultKey,
                store: nativeStore,
                loadedCount: &loadedCount,
                loadedBytes: &loadedBytes
            )
        }
        guard loadedCount > 0 else { return }
        updateAttachmentContent(updated)
        Log.info("db", "loaded local attachment cache cardId=\(cardID) count=\(loadedCount) bytes=\(loadedBytes) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
    }

    /// 卡片离开详情页后释放已解码的附件字节，避免长期占用内存。
    func releaseCachedAttachments(cardID: UUID) {
        guard let cardIndex = database.cards.firstIndex(where: { $0.id == cardID }) else { return }
        var updated = database
        var releasedCount = 0
        for attachmentIndex in updated.cards[cardIndex].images.indices {
            releasedCount += discardCachedAttachment(
                &updated.cards[cardIndex].images[attachmentIndex], cardID: cardID)
        }
        for attachmentIndex in updated.cards[cardIndex].files.indices {
            releasedCount += discardCachedAttachment(
                &updated.cards[cardIndex].files[attachmentIndex], cardID: cardID)
        }
        guard releasedCount > 0 else { return }
        updateAttachmentContent(updated)
        Log.info("db", "released local attachment memory cardId=\(cardID) count=\(releasedCount)")
    }

    func rememberAttachmentCache(in database: PasswordDatabase) {
        for card in database.cards {
            for attachment in card.images + card.files where attachment.data != nil {
                let version = AttachmentDownloadLedger.Version(
                    cardID: card.id,
                    attachmentID: attachment.id,
                    contentVersion: attachment.contentVersion
                )
                if let data = attachment.data {
                    attachmentCacheBytes[version] = data.count
                }
            }
        }
    }

    /// Includes locally cached attachment bytes in a backup without changing the active view.
    func databaseForBackup() throws -> PasswordDatabase {
        guard let nativeStore, let vaultKey else {
            throw DatabaseStore.StoreError(L10n.t("sync_error"))
        }
        var snapshot = database
        for cardIndex in snapshot.cards.indices {
            let cardID = snapshot.cards[cardIndex].id
            for index in snapshot.cards[cardIndex].images.indices {
                try hydrateBackupAttachment(
                    &snapshot.cards[cardIndex].images[index], cardID: cardID,
                    store: nativeStore, vaultKey: vaultKey)
            }
            for index in snapshot.cards[cardIndex].files.indices {
                try hydrateBackupAttachment(
                    &snapshot.cards[cardIndex].files[index], cardID: cardID,
                    store: nativeStore, vaultKey: vaultKey)
            }
        }
        return snapshot
    }

    private func hydrateBackupAttachment(
        _ attachment: inout Attachment,
        cardID: UUID,
        store: SwiftDataVaultStore,
        vaultKey: SymmetricKey
    ) throws {
        guard attachment.data == nil else { return }
        let version = AttachmentDownloadLedger.Version(
            cardID: cardID, attachmentID: attachment.id, contentVersion: attachment.contentVersion)
        guard attachmentCacheBytes[version] != nil else { return }
        guard let data = try store.loadAttachmentContent(
            vaultName: databaseName, cardID: cardID, attachmentID: attachment.id,
            contentVersion: attachment.contentVersion, vaultKey: vaultKey),
              attachment.installDownloadedContent(data, for: attachment.contentVersion) else {
            throw DatabaseStore.StoreError(L10n.t("database_corrupt_error"))
        }
    }

    private func loadCachedAttachment(
        _ attachment: inout Attachment,
        cardID: UUID,
        vaultKey: SymmetricKey,
        store: SwiftDataVaultStore,
        loadedCount: inout Int,
        loadedBytes: inout Int
    ) {
        guard attachment.data == nil else { return }
        let version = AttachmentDownloadLedger.Version(
            cardID: cardID,
            attachmentID: attachment.id,
            contentVersion: attachment.contentVersion
        )
        guard attachmentCacheBytes[version] != nil else { return }
        do {
            guard let data = try store.loadAttachmentContent(
                vaultName: databaseName,
                cardID: cardID,
                attachmentID: attachment.id,
                contentVersion: attachment.contentVersion,
                vaultKey: vaultKey
            ) else {
                attachmentCacheBytes.removeValue(forKey: version)
                return
            }
            guard attachment.installDownloadedContent(data, for: attachment.contentVersion) else { return }
            loadedCount += 1
            loadedBytes += data.count
        } catch {
            attachmentCacheBytes.removeValue(forKey: version)
            Log.error("db", "local attachment cache load failed cardId=\(cardID) attachmentId=\(attachment.id): \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    private func discardCachedAttachment(_ attachment: inout Attachment, cardID: UUID) -> Int {
        guard attachment.data != nil else { return 0 }
        let version = AttachmentDownloadLedger.Version(
            cardID: cardID,
            attachmentID: attachment.id,
            contentVersion: attachment.contentVersion
        )
        guard attachmentCacheBytes[version] != nil else { return 0 }
        attachment.discardLocalContent()
        return 1
    }

    /// 判断稳定附件是否受用户保留策略保护，不参与自动缓存淘汰。
    func isAttachmentKeptOffline(cardID: UUID, attachmentID: UUID) -> Bool {
        attachmentDownloadLedger?.offlineAttachments.contains(
            .init(cardID: cardID, attachmentID: attachmentID)) == true
    }

    /// 先持久化用户的保留选择，再为缺失内容安排下载。
    func setAttachmentKeptOffline(_ isKeptOffline: Bool, cardID: UUID, attachmentID: UUID) {
        guard isAttachmentSessionUnlocked else { return }
        let identity = AttachmentDownloadLedger.Identity(cardID: cardID, attachmentID: attachmentID)
        do {
            try updateAttachmentLedger { $0.setKeptOffline(isKeptOffline, for: identity) }
            Log.info("sync", "attachment offline retention cardId=\(cardID) attachmentId=\(attachmentID) enabled=\(isKeptOffline)")
            if isKeptOffline {
                prioritizeAttachmentDownload(cardID: cardID, retryFailures: true)
            }
        } catch {
            reportAttachmentLedgerError(error)
        }
    }

    /// 返回附件缺失、等待重试或暂停下载的具体原因。
    func attachmentDownloadStatusText(cardID: UUID) -> String? {
        guard let card = database.card(id: cardID), hasMissingAttachmentContent(card) else { return nil }
        if attachmentLedgerUnavailable { return L10n.t("attachment_download_state_error") }
        let versions = missingRemoteAttachmentVersions(in: card)
        for version in versions {
            guard let record = attachmentDownloadLedger?.records[version] else { continue }
            if record.isEvicted { return L10n.t("attachment_cache_evicted") }
            switch record.failure {
            case .authorization: return L10n.t("attachment_download_authorization_required")
            case .integrity: return L10n.t("sync_attachment_integrity_failed")
            case .unavailable, .permanent: return L10n.t("attachment_download_unavailable")
            case .storage: return L10n.t("attachment_cache_space_limited")
            case .transient:
                return L10n.t(record.retryAt == nil ? "attachment_retry_limit" : "attachment_retry_scheduled")
            case nil: continue
            }
        }
        return L10n.t("attachment_content_unavailable")
    }

    func resumeAttachmentDownloads() {
        requeueCurrentDownloadIfDisallowed()
        guard attachmentDownloadTask == nil, nextAttachmentDownloadIsAllowed else { return }
        attachmentDownloadTask = Task { [weak self] in await self?.drainAttachmentDownloads() }
    }

    /// 取消当前会话的下载任务；磁盘上的重试限制和保留设置保持不变。
    func cancelAttachmentDownloads() {
        attachmentCacheBytes.removeAll()
        attachmentDownloadQueue.cancelInFlight()
        attachmentDownloadTask?.cancel()
        attachmentRetryTask?.cancel()
        attachmentRetryTask = nil
        attachmentDownloadQueue.removeAll()
        attachmentDownloadLedger = nil
        attachmentLedgerUnavailable = false
        clearAttachmentDownloadStates()
    }

    private var isAttachmentSessionUnlocked: Bool { phase == .unlocked }

    private func updateAttachmentLedger(_ update: (inout AttachmentDownloadLedger) -> Void) throws {
        guard let nativeStore else { throw DatabaseStore.StoreError(L10n.t("sync_error")) }
        var ledger = try attachmentDownloadLedger
            ?? nativeStore.loadAttachmentDownloadLedger(vaultName: databaseName)
        let previous = ledger
        update(&ledger)
        if ledger != previous {
            try nativeStore.saveAttachmentDownloadLedger(ledger, vaultName: databaseName)
        }
        objectWillChange.send()
        attachmentDownloadLedger = ledger
    }

    private func reportAttachmentLedgerError(_ error: Error) {
        let shouldNotify = !attachmentLedgerUnavailable
        attachmentLedgerUnavailable = true
        attachmentRetryTask?.cancel()
        attachmentDownloadTask?.cancel()
        Log.error("sync", "attachment policy persistence failed; downloads paused: \(error)")
        if shouldNotify { AppToast.shared.show(L10n.t("attachment_download_state_error")) }
    }

    private func enqueueAttachmentDownload(cardID: UUID, prioritized: Bool) {
        guard isAttachmentSessionUnlocked, relayBound, !attachmentLedgerUnavailable,
              let card = database.card(id: cardID), hasMissingAttachmentContent(card),
              let ledger = attachmentDownloadLedger else { return }
        let ready = missingRemoteAttachmentVersions(in: card).contains { ledger.isReady($0) }
        guard ready else {
            setAttachmentDownloadState(.failed, cardID: cardID)
            return
        }
        attachmentDownloadQueue.enqueue(cardID: cardID, prioritized: prioritized)
        setAttachmentDownloadState(
            attachmentDownloadQueue.isActive(cardID: cardID) ? .downloading : .queued, cardID: cardID)
        resumeAttachmentDownloads()
    }

    private func drainAttachmentDownloads() async {
        defer {
            attachmentDownloadTask = nil
            // 其他卡片的重试时间可能更晚；休眠前重新扫描已到期的附件版本。
            if isAttachmentSessionUnlocked { scheduleMissingAttachmentDownloads() }
        }
        while !Task.isCancelled, nextAttachmentDownloadIsAllowed {
            guard let binding = relay.binding(database: databaseName),
                  let token = relay.token(database: databaseName), let snapshotKey = vaultKey,
                  let entry = attachmentDownloadQueue.takeNext() else { break }
            let cardID = entry.cardID
            let name = databaseName
            let sessionID = syncSessionID
            let key = RowSyncKey(raw: snapshotKey.withUnsafeBytes { Data($0) })
            var activeVersion: AttachmentDownloadLedger.Version?
            let startedAt = Date()
            do {
                while syncState == .syncing {
                    try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let card = database.card(id: cardID),
                      let version = missingRemoteAttachmentVersions(in: card)
                        .first(where: { attachmentDownloadLedger?.isReady($0) == true }) else {
                    attachmentDownloadQueue.finish(cardID: cardID)
                    refreshAttachmentDownloadState(cardID: cardID)
                    continue
                }
                activeVersion = version
                setAttachmentDownloadState(.downloading, cardID: cardID)
                let protected = Set(AttachmentDownloadLedger.versions(in: database, cardID: cardID))
                // 校验后按实际大小预留空间；按最大估算值预留会误暂停仍能放入预算的小文件。
                try applyAttachmentCacheBudget(incomingBytes: 0,
                                               protecting: protected, key: key, vaultKey: snapshotKey)
                Log.info("sync", "attachment download started cardId=\(cardID) attachmentId=\(version.identity.attachmentID) priority=\(entry.isPrioritized)")
                let data = try await RowSync.downloadAttachment(
                    version: version, client: relayClient, token: token, vaultId: binding.vaultId, key: key)
                try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                guard relay.binding(database: name) == binding, relay.token(database: name) == token else {
                    throw CancellationError()
                }
                while syncState == .syncing {
                    try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                    try await Task.sleep(for: .milliseconds(100))
                }
                try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                guard relay.binding(database: name) == binding, relay.token(database: name) == token else {
                    throw CancellationError()
                }
                try applyAttachmentCacheBudget(incomingBytes: data.count, protecting: protected,
                                               key: key, vaultKey: snapshotKey)
                var current = database
                if RowSync.installDownloadedAttachmentContent(data, for: version, into: &current) {
                    try commitSyncSnapshot(current, name: name, vaultKey: snapshotKey, state: rowSync)
                    updateAttachmentContent(current)
                    attachmentCacheBytes[version] = data.count
                    if selectedCardId != cardID {
                        releaseCachedAttachments(cardID: cardID)
                    }
                    pushExtensionSnapshot(database: current, name: name, vaultKey: snapshotKey)
                    try updateAttachmentLedger {
                        $0.recordSuccess(for: version)
                        $0.reconcile(with: current)
                    }
                }
                let priority = attachmentDownloadQueue.inFlightIsPrioritized
                attachmentDownloadQueue.finish(cardID: cardID)
                refreshAttachmentDownloadState(cardID: cardID)
                enqueueAttachmentDownload(cardID: cardID, prioritized: priority)
                Log.info("sync", "attachment download finished cardId=\(cardID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            } catch is CancellationError {
                attachmentDownloadQueue.finish(cardID: cardID)
                break
            } catch {
                let priority = attachmentDownloadQueue.inFlightIsPrioritized
                attachmentDownloadQueue.finish(cardID: cardID)
                guard !Task.isCancelled, isAttachmentSessionUnlocked, relayBound,
                      syncSessionID == sessionID, databaseName == name, vaultKey == snapshotKey,
                      relay.binding(database: name) == binding, relay.token(database: name) == token else { break }
                guard let activeVersion else {
                    reportAttachmentLedgerError(error)
                    break
                }
                let classification = AttachmentDownloadFailure.classify(error)
                do {
                    try updateAttachmentLedger {
                        $0.recordFailure(for: activeVersion, failure: classification.failure,
                                         minimumDelay: classification.minimumDelay)
                    }
                } catch {
                    reportAttachmentLedgerError(error)
                    break
                }
                refreshAttachmentDownloadState(cardID: cardID)
                enqueueAttachmentDownload(cardID: cardID, prioritized: priority)
                Log.error("sync", "attachment download failed cardId=\(cardID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)): \(error)")
            }
        }
    }

    private func refreshAttachmentDownloadState(cardID: UUID) {
        let isMissing = database.card(id: cardID).map(hasMissingAttachmentContent) ?? false
        setAttachmentDownloadState(isMissing ? .failed : nil, cardID: cardID)
    }

    private func applyAttachmentCacheBudget(
        incomingBytes: Int, protecting: Set<AttachmentDownloadLedger.Version>,
        key: RowSyncKey, vaultKey: SymmetricKey
    ) throws {
        guard let ledger = attachmentDownloadLedger else { throw RowSyncSafetyError.invalidResponse }
        let plan = try AttachmentCachePolicy.makePlan(
            database: database, state: rowSync, key: key, ledger: ledger,
            incomingBytes: incomingBytes, protectedVersions: protecting,
            cachedContentBytes: attachmentCacheBytes)
        guard plan.hasCapacity else { throw CocoaError(.fileWriteOutOfSpace) }
        let available = try store.root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity
        // 加密 XML 和原子暂存会产生额外开销，所需空间应高于下载内容本身大小。
        let requiredBytes = max(64 * 1024 * 1024, incomingBytes * 4)
        if let available, available < requiredBytes { throw CocoaError(.fileWriteOutOfSpace) }
        guard !plan.evictedVersions.isEmpty else { return }
        guard let nativeStore else { throw DatabaseStore.StoreError(L10n.t("sync_error")) }
        try nativeStore.saveAttachmentDownloadLedger(plan.ledger, vaultName: databaseName)
        attachmentDownloadLedger = plan.ledger
        try commitSyncSnapshot(plan.database, name: databaseName, vaultKey: vaultKey, state: rowSync)
        for version in plan.evictedVersions {
            try nativeStore.evictAttachmentContent(
                vaultName: databaseName,
                attachmentID: version.identity.attachmentID,
                contentVersion: version.contentVersion
            )
        }
        updateAttachmentContent(plan.database)
        for version in plan.evictedVersions {
            attachmentCacheBytes.removeValue(forKey: version)
        }
        pushExtensionSnapshot(database: plan.database, name: databaseName, vaultKey: vaultKey)
        Log.info("sync", "attachment cache evicted versions=\(plan.evictedVersions.count) cachedBytes=\(plan.cachedBytes)")
    }

    private func scheduleAttachmentRetry() {
        attachmentRetryTask?.cancel()
        attachmentRetryTask = nil
        guard isAttachmentSessionUnlocked, relayBound, !attachmentLedgerUnavailable,
              let ledger = attachmentDownloadLedger else { return }
        let retryAt = database.cards
            .flatMap(missingRemoteAttachmentVersions(in:))
            .compactMap { ledger.records[$0]?.retryAt }
            .filter { $0 > Date() }
            .min()
        guard let retryAt else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let delay = max(0, retryAt.timeIntervalSinceNow)
        attachmentRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            guard let self, self.isAttachmentSessionUnlocked,
                  self.databaseName == name, self.syncSessionID == sessionID else { return }
            self.attachmentRetryTask = nil
            self.scheduleMissingAttachmentDownloads()
        }
    }

    private var nextAttachmentDownloadIsAllowed: Bool {
        guard isAttachmentSessionUnlocked, relayBound, !attachmentLedgerUnavailable,
              relay.token(database: databaseName) != nil, vaultKey != nil,
              let next = attachmentDownloadQueue.firstCardID else { return false }
        return isAttachmentNetworkAllowed(prioritized: attachmentDownloadQueue.isPrioritized(next))
    }

    private func isAttachmentNetworkAllowed(prioritized: Bool) -> Bool {
        if prioritized { return AttachmentDownloadPolicy.allowsPrioritized(attachmentNetworkState) }
        return AttachmentDownloadPolicy.allowsBackground(
            on: attachmentNetworkState, allowsCellular: settings.downloadAttachmentsOnCellular, allowsUnknown: settings.downloadAttachmentsOnUnknownNetwork)
    }

    private func requeueCurrentDownloadIfDisallowed() {
        guard let cardID = attachmentDownloadQueue.inFlightCardID,
              !isAttachmentNetworkAllowed(prioritized: attachmentDownloadQueue.inFlightIsPrioritized) else { return }
        attachmentDownloadQueue.requeueInFlight()
        setAttachmentDownloadState(.queued, cardID: cardID)
        attachmentDownloadTask?.cancel()
    }

    private func hasMissingAttachmentContent(_ card: Card) -> Bool {
        !missingRemoteAttachmentVersions(in: card).isEmpty
    }

    private func missingRemoteAttachmentVersions(in card: Card) -> [AttachmentDownloadLedger.Version] {
        (card.images + card.files).compactMap { attachment in
            guard !attachment.hasContent, attachment.hasPersistentID,
                  attachment.hasPersistentContentVersion else { return nil }
            let version = AttachmentDownloadLedger.Version(
                cardID: card.id,
                attachmentID: attachment.id,
                contentVersion: attachment.contentVersion
            )
            return attachmentCacheBytes[version] == nil ? version : nil
        }
    }
}
