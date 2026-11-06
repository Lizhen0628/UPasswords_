import Foundation
import SwiftUI
import Combine
import CryptoKit
import Network
import UPasswordsCore
import UPasswordsPersistence
import UPasswordsNetworking

/// 主会话控制器，负责会话状态、密码库持久化及按侧栏选择生成卡片列表。
/// 职责拆分(同类型 extension,便于按域浏览):
/// - 本文件:会话状态、启动引导、锁定/解锁生命周期、持久化、自动锁
/// - AppContext+CardList:侧栏卡片列表策略、搜索、最近打开
/// - AppContext+Actions:卡片/标签 CRUD、初始化清单、历史
/// - AppContext+Sync:修改密码、备份、行级云同步及本地同步快照提交
@MainActor
final class AppContext: ObservableObject {
    @MainActor
    final class SearchState {
        @MainActor
        final class Input: ObservableObject {
            @Published private(set) var text = ""

            fileprivate func update(_ text: String) {
                self.text = text
            }
        }

        @MainActor
        final class Results: ObservableObject {
            @Published private(set) var query = ""

            fileprivate func apply(_ query: String) {
                self.query = query
            }
        }

        private static let debounceInterval = Duration.milliseconds(200)

        let input = Input()
        let results = Results()

        private lazy var debouncer = SearchInputDebouncer(interval: Self.debounceInterval) { [weak self] text in
            guard let self, self.results.query != text else { return }
            self.results.apply(text)
            Log.info("ui", "search apply chars=\(text.count)")
        }

        func setText(_ text: String) {
            input.update(text)
            debouncer.textChanged(text)
        }

        func clear() {
            guard !input.text.isEmpty || !results.query.isEmpty else { return }
            input.update("")
            debouncer.clear()
            Log.info("ui", "search clear")
        }
    }

    struct CardFilterCacheKey: Equatable {
        let databaseRevision: UInt64
        let recentRevision: UInt64
        let selection: SidebarSelection
        let search: String
        let searchByLabels: Bool
        let searchPasswords: Bool
    }

    struct CardSortCacheKey: Equatable {
        let filter: CardFilterCacheKey
        let sorting: String
        let favoritesFirst: Bool
    }

    struct DatabaseSummary: Identifiable {
        let name: String
        let created: Date
        let isMain: Bool

        var id: String { name }
    }

    static let credentialProviderKeychainAccessGroup = PasswordStore.credentialProviderAccessGroup

    enum Phase: Equatable {
        case setup        // SetupWindowController flow (first launch)
        case locked       // LockWindowController
        case unlocked     // MainWindowController
    }

    // MARK: - Published state
    @Published var phase: Phase = .setup {
        didSet {
            syncSessionID = UUID()
            if phase != .unlocked {
                // 离开解锁态时撤销只对当前会话有效的后台工作。
                cancelAttachmentDownloads()
                cancelBackupCapture()
            }
            Log.info("lifecycle", "phase \(oldValue) → \(phase)")
            savePendingPersonalInfoIfNeeded()
        }
    }
    @Published var database = PasswordDatabase() {
        didSet {
            guard !isApplyingAttachmentContentUpdate else { return }
            databaseRevision &+= 1
            cardIndexByID = [:]
            for (index, card) in database.cards.enumerated() {
                cardIndexByID[card.id] = index
            }
            reusedPasswordCardIDs = SamePasswordsService.cardIDsWithReusedPasswords(
                cards: database.activeCards)
            sidebarCountsAreCurrent = false
        }
    }
    var isApplyingAttachmentContentUpdate = false
    var databaseRevision: UInt64 = 0
    var recentRevision: UInt64 = 0
    var cardIndexByID: [UUID: Int] = [:]
    var filteredCardIDsCacheKey: CardFilterCacheKey?
    var filteredCardIDsCache: [UUID] = []
    var sortedCardIDsCacheKey: CardSortCacheKey?
    var sortedCardIDsCache: [UUID] = []

    func updateAttachmentContent(_ updatedDatabase: PasswordDatabase) {
        isApplyingAttachmentContentUpdate = true
        database = updatedDatabase
        isApplyingAttachmentContentUpdate = false
    }
    private(set) var reusedPasswordCardIDs = Set<UUID>()
    var sidebarCardCounts: [SidebarSelection: Int] = [:]
    var sidebarActiveCardIDs = Set<UUID>()
    var sidebarCountsCalculatedAt = Date.distantPast
    var sidebarCountsAreCurrent = false
    @Published var syncCursorRecoveryRequired = false
    /// 仅保存在内存中的首次设置资料；新建或恢复密码库并解锁后消费。
    var pendingPersonalInfo: PersonalInfoDraft?
    @Published var databaseName: String = "" {
        didSet {
            guard oldValue != databaseName else { return }
            syncCursorRecoveryRequired = false
            syncSessionID = UUID()
            cancelAttachmentDownloads()
            cancelBackupCapture()
            Log.info("lifecycle", "databaseName \"\(oldValue.isEmpty ? "∅" : oldValue)\" → \"\(databaseName.isEmpty ? "∅" : databaseName)\"")
        }
    }
    @Published var selection: SidebarSelection = .special(.allCards)
    @Published var selectedCardId: UUID? = nil
    let searchState = SearchState()
    /// 编辑工作副本。故意不用 @Published:填字段值时每个按键都会写入,
    /// @Published 会逐键广播 objectWillChange 让整棵视图树重渲染(输入卡顿)。
    /// didSet 只在「打开(nil → 有值)」和「关闭(有值 → nil)」时通知视图;
    /// 编辑中的键入写入(有值 → 有值)对 UI 不可见,TextField 自己维护显示。
    var editDraft: EditCardModel? = nil {
        didSet {
            let opened = oldValue == nil && editDraft != nil
            let closed = oldValue != nil && editDraft == nil
            if opened || closed {
                objectWillChange.send()
                Log.info("ui", "editDraft \(opened ? "open" : "close") cardId=\(editDraft?.card.id.uuidString.prefix(8) ?? oldValue?.card.id.uuidString.prefix(8) ?? "nil")… isNew=\(editDraft?.isNew ?? false)")
            }
        }
    }
    @Published var activeSheet: AppSheet? = nil {
        didSet {
            guard oldValue != activeSheet else { return }
            Log.info("ui", "sheet \(oldValue.map { "open \($0.id)" } ?? "nil") → \(activeSheet.map { "open \($0.id)" } ?? "close")")
        }
    }
    @Published var syncState: SyncState = .disabled
    @Published var lastSync: Date? = nil
    /// 远端密文用本机不知道的密码加密(对端刚改过主密码/数据损坏):
    /// 云同步设置页据此展示「接管/覆盖」修复入口(与 iOS 同语义)。
    @Published var syncRemoteUnreadable = false
    /// relay 账户/绑定状态版本号:登录、登出、绑定/解绑、会话失效时自增。
    /// RelayStore 只是 defaults 读写,不经 @Published——没有这个版本号,
    /// 登录成功后设置页表单不会翻页(用户会误判"登录失败"而反复重试,
    /// 每次重试都在服务端多签发一条会话)。
    @Published private(set) var relayStateVersion = 0
    @Published private(set) var attachmentDownloadStates: [UUID: RowSync.AttachmentDownloadState] = [:]
    @Published private(set) var backupListVersion = 0

    func backupListDidChange() {
        backupListVersion += 1
    }

    /// relay 状态版本号自增(跨文件扩展经此触发设置页重渲染,setter 保持私有)。
    func relayStateChanged() {
        relayStateVersion += 1
    }

    func setAttachmentDownloadState(
        _ state: RowSync.AttachmentDownloadState?, cardID: UUID
    ) {
        var states = attachmentDownloadStates
        states[cardID] = state
        attachmentDownloadStates = states
    }

    func clearAttachmentDownloadStates() {
        attachmentDownloadStates.removeAll()
    }
    @Published var lastSyncFailed: Date? = nil
    @Published var failedUnlockAttempts = 0

    enum SyncState: Equatable {
        case disabled, idle, syncing, error(String)
    }

    /// 行级同步状态(游标/revision/脏集合/快照基线);解锁时按库装载。
    /// 故意不用 @Published:同步状态呈现走 syncState,这里高频读写不驱动逐条 UI。
    var rowSync = RowSyncState()
    var backupCaptureTask: Task<Void, Never>?
    /// 跨文件同步扩展捕获此标识,锁定/解锁/切库后旧异步任务不得提交。
    var syncSessionID = UUID()
    var conflictCandidateCopyOperationID: UUID?
    // 空闲追踪用,不进 UI。故意不用 @Published:活动监视器把每次键盘/鼠标
    // 事件都算作活动,若发布会在打字时逐键触发整棵视图树重渲染(输入卡顿)。
    var lastActivity: Date = Date()
    // 网站图标抓取状态(逻辑在 AppContext+Icons.swift):
    // 本会话已尝试抓取的卡片,防止反复请求失败站点;补抓串行任务句柄。
    var iconFetchAttempted = Set<UUID>()
    var iconBackfillTask: Task<Void, Never>? = nil
    var attachmentNetworkMonitor: NWPathMonitor?
    var attachmentNetworkState = AttachmentNetworkState.unknown
    var attachmentDownloadQueue = AttachmentDownloadQueue()
    var attachmentDownloadLedger: AttachmentDownloadLedger?
    var attachmentCacheBytes: [AttachmentDownloadLedger.Version: Int] = [:]
    var attachmentNetworkObserved = false
    var attachmentLedgerUnavailable = false
    var attachmentRetryTask: Task<Void, Never>?
    var attachmentDownloadTask: Task<Void, Never>?

    /// 仅在密码库解锁期间保存在内存中的主密码。
    /// 仅生命周期代码(unlock/lock/erase/changePassword)可写入。
    nonisolated(unsafe) var password: String = ""
    /// v2 信封加密的库密钥(解锁时由信封解出;保存/同步解密本体用,与主密码解耦)。
    /// nonisolated(unsafe):与 password 同一先例,全部读写都在 @MainActor 上。
    nonisolated(unsafe) var vaultKey: SymmetricKey? = nil

    let settings = AppSettings.shared
    let store = DatabaseStore.shared
    /// SwiftData 是迁移后的本地业务数据存储；迁移过渡期仍保留旧加密文件以便回滚。
    lazy var nativeStore: SwiftDataVaultStore? = {
        do {
            return try SwiftDataVaultStore(root: store.root)
        } catch {
            Log.error("db", "SwiftData store unavailable: \(error)")
            return nil
        }
    }()
    private var cancellables = Set<AnyCancellable>()
    private var autoLockTimer: Timer? = nil
    @Published private(set) var biometricUnlockRequestID: UUID?
    /// 云同步到期 ticker(5s 一跳,由守卫条件过滤;逻辑见 AppContext+Sync)。
    /// internal:extension 在独立文件,无法用 private(规范 3.7)。
    var autoSyncTimer: Timer? = nil
    /// 泄露库自动检查 ticker(60s 一跳;逻辑见 AppContext+Security)。
    var breachCheckTimer: Timer? = nil
    /// 泄露检查进行中标志:防止 60s ticker 在一次长检查未完成时重复发起。
    var breachCheckInFlight = false

    static let shared = AppContext()

    init() {
        bootstrapPhase()
        installActivityMonitor()
        startAttachmentNetworkMonitor()
    }

    // MARK: - Bootstrap

    private func bootstrapPhase() {
        Log.info("lifecycle", "bootstrap: mainDatabaseName=\"\(store.mainDatabaseName)\" databases=\(dbsInfo().map(\.name))")
        #if DEBUG
        // 复现「锁定→解锁」过渡:UP_SCREENSHOT_BOOT=2 时建库(如有)→启动进锁定态,
        // 3 秒后自动解锁(自动化测试用,release 不编译)。
        if ProcessInfo.processInfo.environment["UP_SCREENSHOT_BOOT"] == "2" {
            Log.info("lifecycle", "UP_SCREENSHOT_BOOT=2 (debug automation)")
            if !databaseExists("TestDB") {
                try? createManagedDatabase(name: "TestDB", password: "screenshot")
                store.mainDatabaseName = "TestDB"
            }
            databaseName = "TestDB"
            phase = .locked
            // 存量 GCD:主线程延时,回调仍在主队列,无需回主线程
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.phase == .locked else { return }
                // 二进制重建后钥匙串 ACL 会拒绝读取,回退到建库密码
                let pw = PasswordStore.loadPassword(databaseName: self.databaseName) ?? "screenshot"
                if PasswordStore.loadPassword(databaseName: self.databaseName) == nil {
                    Log.warn("keychain", "stored password unreadable (ACL/signature change?) → fallback to build password")
                }
                try? self.unlock(name: self.databaseName, password: pw)
                // UP_SCREENSHOT_CARD=first/short:解锁后造演示卡并选中(详情页截图自动化)。
                // 幂等:各演示卡按标题判断,存在即跳过。
                if let screenshotCard = ProcessInfo.processInfo.environment["UP_SCREENSHOT_CARD"],
                   !screenshotCard.isEmpty,
                   let spec = Templates.spec(id: 102) {
                    // 演示值(非真实凭据);前两张卡共用同一密码以复现「重复使用的密码」警告
                    if !database.cards.contains(where: { $0.title == "国金" }) {
                        var a = Templates.makeCard(from: spec)
                        a.title = "国金"
                        a.fields = a.fields.map { f in
                            var f = f
                            switch f.type {
                            case .login: f.value = "8886800628"
                            case .password: f.value = "Xk7#pQ2vTr0ub4dor"
                            case .website: f.value = "example.com"
                            default: break
                            }
                            return f
                        }
                        a.notes = "第二因子使用硬件密钥。"
                        a.labelIds = []
                        upsertCard(a)
                        var b = Templates.makeCard(from: spec)
                        b.title = "国金备用"
                        b.fields = b.fields.map { f in
                            var f = f
                            if f.type == .password { f.value = "Xk7#pQ2vTr0ub4dor" }
                            return f
                        }
                        upsertCard(b)
                        Log.info("ui", "screenshot demo cards created")
                    }
                    // 短密码卡:复现 ≤6 位全打点掩码与「弱密码」警告卡
                    if !database.cards.contains(where: { $0.title == "短密码示例" }) {
                        var c = Templates.makeCard(from: spec)
                        c.title = "短密码示例"
                        c.fields = c.fields.map { f in
                            var f = f
                            if f.type == .password { f.value = "abc12" }
                            return f
                        }
                        upsertCard(c)
                        Log.info("ui", "screenshot demo short-password card created")
                    }
                    // UP_SCREENSHOT_CARD=short 选中短密码卡,其余选中「国金」
                    let selectTitle = screenshotCard == "short" ? "短密码示例" : "国金"
                    if let demo = database.cards.first(where: { $0.title == selectTitle }) {
                        selectedCardId = demo.id
                        Log.info("ui", "screenshot select demo cardId=\(demo.id)")
                        // 截图自动化:顺带触发一次复制提示,验证 HUD 样式(2s 后自动消失)
                        AppToast.shared.show(L10n.t("text_copied_message"))
                    }
                }
                // UP_SCREENSHOT_EDITOR=<templateId>:解锁后直接打开该模板的新卡编辑表单
                if let specId = ProcessInfo.processInfo.environment["UP_SCREENSHOT_EDITOR"].flatMap(Int.init),
                   let spec = Templates.spec(id: specId) {
                    // 存量 GCD:主线程延时,回调仍在主队列,无需回主线程
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSApp.activate(ignoringOtherApps: true)
                        // 主窗口搬到当前空间(同 BOOT=1),全屏应用占据当前空间时截图才可见
                        for w in NSApp.windows where w.frame.width > 800 {
                            w.setFrameOrigin(NSPoint(x: 120, y: 140))
                            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                            w.makeKeyAndOrderFront(nil)
                        }
                        var m = EditCardModel(card: Templates.makeCard(from: spec))
                        m.isNew = true
                        AppContext.shared.editDraft = m
                    }
                }
            }
            return
        }
        #endif
        #if DEBUG
        // 截图/自动化专用:UP_SCREENSHOT_BOOT=1 时跳过向导直接建库解锁。
        // 仅 DEBUG 构建生效,release 行为不变。
        if ProcessInfo.processInfo.environment["UP_SCREENSHOT_BOOT"] == "1" {
            Log.info("lifecycle", "UP_SCREENSHOT_BOOT=1 (screenshot automation)")
            UserDefaults.standard.set("zh-Hans", forKey: "app.language")
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("setup.done.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
            settings.showWhatsNewAtStartup = false
            settings.autoLockSeconds = 0
            settings.fastUnlock = false
            let name = "UPasswords"
            if !databaseExists(name) {
                do {
                    // 走与向导「继续」相同的 createDatabase 路径,复现 setupPlan 弹窗
                    try createDatabase(name: name, password: "screenshot", touchID: false)
                } catch {
                    FileHandle.standardError.write(Data("[UP_SCREENSHOT_BOOT] create failed: \(error)\n".utf8))
                }
                // createDatabase 内部已 unlock + 弹出 setupPlan
                // 存量 GCD:主线程延时,回调仍在主队列,无需回主线程
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.activate(ignoringOtherApps: true)
                    for w in NSApp.windows where w.frame.width > 800 {
                        w.setFrameOrigin(NSPoint(x: 120, y: 140))
                        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                        w.makeKeyAndOrderFront(nil)
                    }
                }
                // Timer 调度在主 runloop,回调必在主线程;assumeIsolated 依据规范 11.3
                Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                // UP_SCREENSHOT_EDITOR=<templateId>:解锁后直接打开该模板的新卡编辑表单
                if let specId = ProcessInfo.processInfo.environment["UP_SCREENSHOT_EDITOR"].flatMap(Int.init) {
                    // 存量 GCD:主线程延时,回调仍在主队列,无需回主线程
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        NSApp.activate(ignoringOtherApps: true)
                        guard let spec = Templates.spec(id: specId) else { return }
                        var m = EditCardModel(card: Templates.makeCard(from: spec))
                        m.isNew = true
                        AppContext.shared.editDraft = m
                    }
                }
                return
            }
        }
        #endif
        let dbs = dbsInfo()
        if dbs.isEmpty {
            Log.info("lifecycle", "bootstrap → phase=setup (no databases)")
            phase = .setup
        } else {
            Log.info("lifecycle", "bootstrap → phase=locked (databases present)")
            phase = .locked
            databaseName = databaseExists(store.mainDatabaseName)
                ? store.mainDatabaseName
                : (dbs.first?.name ?? "Main")
        }
    }

    // MARK: - Setup / lifecycle

    /// 创建默认内容的本地库，配置可选生物识别副本后解锁。
    ///
    /// - Parameters:
    ///   - name: 仅含字母数字的新库名。
    ///   - password: 本地库主密码。
    ///   - touchID: 是否尝试启用快速解锁。
    /// - Throws: 建库或解锁失败的格式、加密及文件错误。
    func createDatabase(name: String, password: String, touchID: Bool) throws {
        Log.info("lifecycle", "createDatabase \"\(name)\" touchID=\(touchID)")
        do {
            try createManagedDatabase(name: name, password: password)
        } catch {
            Log.error("lifecycle", "createDatabase \"\(name)\" failed: \(error)")
            throw error
        }
        store.mainDatabaseName = name
        if touchID && PasswordStore.biometricAvailable() {
            PasswordStore.savePasswordForBiometric(
                password,
                databaseName: name,
                sharedAccessGroup: Self.credentialProviderKeychainAccessGroup)
        }
        try unlock(name: name, password: password)
        activeSheet = .setupPlan
    }

    /// 完成本地文件校验和解密后装载会话，启动同步、备份及安全检查。
    ///
    /// 所有必需本地组件加载成功后才发布解锁状态。
    /// - Parameters:
    ///   - name: 本地库名。
    ///   - password: 主密码明文，仅会话期持有。
    /// - Throws: 文件、同步状态、信封、解密或 XML 错误。
    func unlock(name: String, password: String) throws {
        Log.info("lifecycle", "unlock \"\(name)\"")
        let loaded: (PasswordDatabase, SymmetricKey, RowSyncState,
                     [AttachmentDownloadLedger.Version: Int], AttachmentDownloadLedger)
        do {
            let nativeStore = try managedStoreForVault(name: name, password: password)
            let dbAndKey = try nativeStore.loadUnlocked(
                name: name, password: password, hydrateAttachments: false)
            let cacheBytes = try nativeStore.cachedAttachmentBytes(vaultName: name)
            let (db, vek) = dbAndKey
            let storedState = try nativeStore.loadSyncState(vaultName: name)
            let state = storedState ?? RowSyncState()
            if storedState == nil { try nativeStore.saveSyncState(state, vaultName: name) }
            let attachmentLedger = try nativeStore.loadAttachmentDownloadLedger(vaultName: name)
            loaded = (db, vek, state, cacheBytes, attachmentLedger)
        } catch {
            Log.warn("lifecycle", "unlock \"\(name)\" failed: \(error)")
            throw error
        }
        database = loaded.0
        vaultKey = loaded.1
        databaseName = name
        rowSync = loaded.2
        attachmentCacheBytes = loaded.3
        attachmentDownloadLedger = loaded.4
        Log.info("sync", "restored row sync state for \"\(name)\" (cursor=\(rowSync.cursor), pending=\(rowSync.dirtyUpserts.count + rowSync.dirtyDeletes.count))")
        self.password = password
        phase = .unlocked
        lastActivity = Date() // otherwise the idle timer re-locks right after unlocking
        failedUnlockAttempts = 0
        lastFailedUnlockAt = nil
        selection = .special(.allCards)
        selectedCardId = database.activeCards.first?.id
        Log.info("lifecycle", "unlocked \"\(name)\": \(database.cards.count) cards, \(database.labels.count) labels")
        pushExtensionSnapshot(database: database, name: name, vaultKey: loaded.1)
        CredentialProviderIdentityStore.replace(with: database.activeCards)
        scheduleIconBackfill()
        scheduleAutoBackupIfNeeded()
        startAutoSyncTickerIfNeeded()
        scheduleMissingAttachmentDownloads()
        startBreachCheckTickerIfNeeded()
        // 云同步步骤按 relay 绑定判定(API 为默认通道;网盘入口已隐藏)
        markSetupTaskDoneIf(.cloudSync, when: relayBound)
        markSetupTaskDoneIf(.autoBackup, when: settings.autoBackupEnabled)
        markSetupTaskDoneIf(.touchID, when: settings.fastUnlock && PasswordStore.biometricAvailable())
        // 钥匙串密码副本自愈:他机改密后以新密码重新解锁时,回写新副本
        // (旧副本已在强制锁定时清除;生物识别项随快速解锁配置恢复)
        if let stored = PasswordStore.loadPassword(databaseName: name), stored != password {
            PasswordStore.savePassword(password, databaseName: name)
            if settings.fastUnlock && PasswordStore.biometricAvailable() {
                PasswordStore.savePasswordForBiometric(
                    password,
                    databaseName: name,
                    sharedAccessGroup: Self.credentialProviderKeychainAccessGroup)
            }
            Log.info("keychain", "password copy healed after unlock for \"\(name)\"")
        }
        if let accessGroup = Self.credentialProviderKeychainAccessGroup,
           settings.fastUnlock,
           PasswordStore.biometricAvailable(),
           !PasswordStore.hasBiometricItem(databaseName: name, accessGroup: accessGroup),
           PasswordStore.saveSharedBiometricPassword(
               password,
               databaseName: name,
               accessGroup: accessGroup) {
            Log.info("keychain", "migrated biometric item to Data Protection Keychain for \(name)")
        }
        if ProcessInfo.processInfo.arguments.contains("--enable-autofill-current-vault") {
            enableAutofillForCurrentVaultCredentials()
        }
        // 引导登录在先的库在此自动补绑;信封先行:解锁后即拉取注册表,
        // 密码被他机修改能立刻提示
        Task {
            await relayBindCurrentVaultIfNeeded()
            scheduleMissingAttachmentDownloads()
            await relayRenameCurrentSession()
            await checkRelayPasswordVersion()
        }
        announceStartupSheets()
    }

    /// 解锁结果:只有「密码被拒」计入自毁;本地数据损坏/信封缺失/断网是
    /// 环境故障,输对密码也不该累计销毁计数。
    enum UnlockOutcome {
        case success, wrongPassword, previousPasswordRequired, unavailable
    }

    /// 密码被拒的判定:unwrapVaultKey 唯一以 wrong_password_error 文案抛出,
    /// 信封缺失/格式错误是其他 CipherError/IO 错误——绝不计入自毁。
    /// 供同步扩展区分主密码拒绝与文件、格式或信封故障。
    static func isPasswordRejection(_ error: Error) -> Bool {
        (error as? DatabaseCipher.CipherError)?.message == L10n.t("wrong_password_error")
    }

    /// 解锁(带远端兜底):本地解不开时拉远端信封+本体收敛后重试。
    /// 他机轮换库密钥后，本地仍保留旧钥配套文件；以新密码验证远端信封，
    /// 重建后一次提交新库体、同步状态和新信封。
    /// 密码真错时远端信封同样解不开 → 仍是密码错误,不误导。
    @discardableResult
    func unlockWithRemoteFallback(name: String, password: String) async -> UnlockOutcome {
        do {
            try unlock(name: name, password: password)
            return .success
        } catch {
            guard let binding = relay.binding(database: name),
                  let token = relay.token(database: name) else {
                return Self.isPasswordRejection(error) ? .wrongPassword : .unavailable
            }
            let sessionID = syncSessionID
            let currentName = databaseName
            let originalKey = vaultKey
            do {
                let detail = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
                guard syncSessionID == sessionID, databaseName == currentName,
                      vaultKey == originalKey, !Task.isCancelled else {
                    Log.warn("sync", "remote unlock result discarded after session changed")
                    return .unavailable
                }
                guard let envelopeBytes = detail.envelope else { return .unavailable }
                let vek: SymmetricKey
                do {
                    vek = try DatabaseCipher.unwrapVaultKey(envelopeBytes, password: password)
                } catch {
                    Log.warn("lifecycle", "remote unlock fallback: remote envelope rejected password")
                    return Self.isPasswordRejection(error) ? .wrongPassword : .unavailable
                }
                guard !databaseExists(name) else {
                    Log.info("sync", "remote password accepted; local copy requires password verification")
                    return .previousPasswordRequired
                }
                // 远端是行级密文,走全量重建收敛本地(他机改密后本体随新 VEK 重加密)
                var state: RowSyncState
                do {
                    state = try nativeStore?.loadSyncState(vaultName: name) ?? RowSyncState()
                } catch {
                    Log.error("sync", "remote unlock fallback state load failed: \(error)")
                    return .unavailable
                }
                let db: PasswordDatabase
                do {
                    db = try await RowSync.fullRebuild(
                        client: relayClient, token: token, vaultId: binding.vaultId,
                        key: RowSyncKey(raw: vek.withUnsafeBytes { Data($0) }), state: &state)
                } catch {
                    Log.warn("sync", "remote unlock fallback: rows not reachable yet (\(error))")
                    return .unavailable
                }
                guard syncSessionID == sessionID, databaseName == currentName,
                      vaultKey == originalKey, !Task.isCancelled else {
                    Log.warn("sync", "remote unlock rebuild discarded after session changed")
                    return .unavailable
                }
                try commitSyncSnapshot(db, name: name, vaultKey: vek, state: state, envelope: envelopeBytes)
                Log.info("lifecycle", "remote unlock fallback converged local vault \"\(name)\" (rows rebuilt)")
                do {
                    try unlock(name: name, password: password)
                    return .success
                } catch {
                    Log.error("lifecycle", "remote unlock fallback: retry after convergence failed: \(error)")
                    return Self.isPasswordRejection(error) ? .wrongPassword : .unavailable
                }
            } catch {
                Log.warn("sync", "remote unlock fallback failed: \(error)")
                return .unavailable
            }
        }
    }

    /// 启动提示:What's New + 即将到期卡片提醒。
    private func announceStartupSheets() {
        let version = "1.0"
        if settings.showWhatsNewAtStartup && settings.lastWhatsNewVersion != version {
            settings.lastWhatsNewVersion = version
            activeSheet = .whatsNew
            return
        }
        if !cards(for: .special(.expiring), search: "").isEmpty {
            activeSheet = .expiredCards
        }
    }

    /// 进入锁定相位。
    func lock() {
        guard phase == .unlocked else { return }
        Log.info("lifecycle", "lock \"\(databaseName)\"")
        password = ""
        vaultKey = nil
        phase = .locked
        syncState = .idle
        activeSheet = nil
        editDraft = nil
        // 未决冲突现场随之作废:下次解锁后的同步会重新检测
        // 关闭设置窗等独立窗口,不让它们残留在锁屏之上
        WindowChromeManager.shared.closeAuxiliaryWindows()
        // 锁定即清掉本 App 复制进剪贴板的内容(自动清除关闭/未走完时不残留)
        ClipboardModel.shared.clearIfOurs()
    }

    var touchIDAvailable: Bool {
        PasswordStore.biometricAvailable()
    }

    /// 当前数据库是否已启用 Touch ID 快速解锁(存在生物识别密码副本)。
    var hasBiometricItem: Bool {
        guard let accessGroup = Self.credentialProviderKeychainAccessGroup else { return false }
        return PasswordStore.hasBiometricItem(databaseName: databaseName, accessGroup: accessGroup)
    }

    /// 启用 Touch ID 快速解锁:把当前(已解锁状态下的)数据库密码存为副本。
    /// 偏好设置开关和初始化清单共用。
    func enableTouchIDUnlock() {
        guard phase == .unlocked, !password.isEmpty else {
            Log.warn("keychain", "enableTouchIDUnlock skipped (phase=\(phase), password empty=\(password.isEmpty))")
            return
        }
        PasswordStore.savePasswordForBiometric(
            password,
            databaseName: databaseName,
            sharedAccessGroup: Self.credentialProviderKeychainAccessGroup)
    }

    /// 请求当前锁屏界面发起 Touch ID 验证。
    func unlockWithTouchID() {
        guard phase == .locked, settings.fastUnlock, hasBiometricItem else {
            Log.debug(
                "keychain",
                "unlockWithTouchID skipped (phase=\(phase), fastUnlock=\(settings.fastUnlock), item=\(hasBiometricItem))")
            return
        }
        guard biometricUnlockRequestID == nil else {
            Log.debug("keychain", "unlockWithTouchID skipped (request already in progress)")
            return
        }

        biometricUnlockRequestID = UUID()
        Log.info("keychain", "embedded Touch ID unlock requested for \"\(databaseName)\"")
    }

    /// 用户切换到密码输入时取消正在进行的 Touch ID 请求。
    func cancelTouchIDUnlock() {
        guard biometricUnlockRequestID != nil else { return }
        biometricUnlockRequestID = nil
        Log.info("keychain", "embedded Touch ID unlock cancelled for password entry")
    }

    /// Touch ID 上下文读取受保护项目后，完成对应的解锁请求。
    func completeTouchIDUnlock(
        requestID: UUID,
        databaseName requestedDatabaseName: String,
        password: String?
    ) {
        guard biometricUnlockRequestID == requestID else { return }
        biometricUnlockRequestID = nil
        guard phase == .locked, databaseName == requestedDatabaseName else {
            Log.info("keychain", "embedded Touch ID result discarded after session changed")
            return
        }
        guard let password else {
            Log.warn("keychain", "embedded Touch ID evaluation failed or was cancelled")
            return
        }
        do {
            try unlock(name: requestedDatabaseName, password: password)
            Log.info("keychain", "embedded Touch ID unlock completed")
        } catch {
            Log.warn("keychain", "embedded Touch ID unlock failed at load: \(error)")
        }
    }

    /// 自毁计数滑窗:间隔超过它的两次失败不累计(防跨天/隔周误攒)。
    private static let failedAttemptWindow: TimeInterval = 15 * 60
    private var lastFailedUnlockAt: Date?

    /// 在十五分钟滑动窗口内累计真实密码失败，达到已配置阈值时抹除本地数据。
    func registerFailedAttempt() {
        if let last = lastFailedUnlockAt, Date().timeIntervalSince(last) > Self.failedAttemptWindow {
            failedUnlockAttempts = 0
        }
        lastFailedUnlockAt = Date()
        failedUnlockAttempts += 1
        let limit = settings.selfDestructAttempts
        Log.warn("lifecycle", "failed unlock attempt #\(failedUnlockAttempts)" + (limit > 0 ? " (self-destruct at \(limit))" : ""))
        if limit > 0, failedUnlockAttempts >= limit {
            eraseAllData()
        }
    }

    /// 擦除本地应用数据；云端副本不受影响。
    /// 自毁/手动擦除必须连扩展快照、泄露哈希清单与 relay 登录态一并清:
    /// 残留的密文+信封可被离线爆破,残留令牌可枚举账户。
    func eraseAllData() {
        Log.warn("lifecycle", "ERASE ALL DATA (self-destruct or manual)")
        let databaseNames: Set<String>
        do {
            guard let nativeStore else {
                throw DatabaseStore.StoreError(L10n.t("sync_error"))
            }
            databaseNames = Set(try nativeStore.listVaults().map(\.name) + store.list().map(\.name))
            try nativeStore.deleteAllVaults()
        } catch {
            Log.error("db", "erase all SwiftData vaults failed; legacy data preserved: \(error)")
            AppToast.shared.show(error.localizedDescription)
            return
        }
        for name in databaseNames {
            do {
                try store.delete(name: name)
            } catch {
                Log.error("db", "erase local metadata failed for \(name): \(error)")
                AppToast.shared.show(error.localizedDescription)
            }
        }
        do {
            try SafariSnapshotBridge.removeSnapshots()
        } catch {
            Log.error("db", "shared extension snapshot cleanup failed: \(error)")
            AppToast.shared.show(L10n.t("snapshot_cleanup_failed"))
        }
        CompromisedService.clearDynamicList()
        relay.logout(database: databaseName)
        database = PasswordDatabase()
        databaseName = ""
        password = ""
        phase = .setup
    }

    // MARK: - Persistence

    /// 提交配套本体/状态/信封;失败可能已落 journal,必须废弃旧会话防止覆盖前滚结果。
    /// - Throws: 事务持久化错误。
    func commitSyncSnapshot(_ snapshot: PasswordDatabase, name: String, vaultKey: SymmetricKey,
                            state: RowSyncState, envelope: Data? = nil,
                            rekeyBackupHistoryFrom: SymmetricKey? = nil) throws {
        do {
            guard let nativeStore else {
                throw DatabaseStore.StoreError(L10n.t("sync_error"))
            }
            try nativeStore.replace(
                snapshot,
                name: name,
                envelope: envelope ?? (try nativeStore.envelopeData(vaultName: name)),
                vaultKey: vaultKey,
                revisions: state.revisions,
                previousVaultKey: rekeyBackupHistoryFrom,
                syncState: state,
                attachmentDownloadLedger: name == databaseName ? attachmentDownloadLedger : nil
            )
            rememberAttachmentCache(in: snapshot)
        } catch {
            saveDebounce?.cancel()
            syncSessionID = UUID()
            lock()
            password = ""
            self.vaultKey = nil
            syncState = .error(error.localizedDescription)
            Log.error("sync", "snapshot commit failed; session invalidated: \(error)")
            AppToast.shared.show(error.localizedDescription)
            throw error
        }
    }

    /// 使用当前库密钥保存 SwiftData 库并更新扩展密文快照。
    ///
    /// 锁定状态或密钥缺失时不写盘；调用方不能将返回视为可捕获的成功凭据。
    @discardableResult
    func save() -> Bool {
        guard phase == .unlocked else { return false }
        do {
            // 解锁路径必持库密钥;缺失说明会话状态异常,绝不能退化为其他写法
            guard let vaultKey else {
                Log.error("db", "save \"\(databaseName)\" aborted: no vault key in session")
                return false
            }
            guard let nativeStore else {
                throw DatabaseStore.StoreError(L10n.t("sync_error"))
            }
            try nativeStore.replace(
                database,
                name: databaseName,
                vaultKey: vaultKey,
                revisions: rowSync.revisions,
                syncState: rowSync,
                attachmentDownloadLedger: attachmentDownloadLedger
            )
            rememberAttachmentCache(in: database)
            pushExtensionSnapshot(database: database, name: databaseName, vaultKey: vaultKey)
            CredentialProviderIdentityStore.replace(with: database.activeCards)
            return true
        } catch {
            Log.error("db", "save \"\(databaseName)\" failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
            return false
        }
    }

    /// 启动时仅在用户明确请求后，为当前库中的登录卡片启用自动填充。
    private func enableAutofillForCurrentVaultCredentials() {
        guard phase == .unlocked else { return }
        let credentialIDs = Set(database.activeCards.compactMap { card -> UUID? in
            guard !card.login.isEmpty, !card.password.isEmpty else { return nil }
            return card.id
        })
        let changedCount = database.cards.filter {
            credentialIDs.contains($0.id) && !$0.autofillEnabled
        }.count
        guard changedCount > 0 else {
            Log.info("autofill", "current vault batch enable completed: changed=0")
            return
        }

        var updatedDatabase = database
        let modifiedAt = Date().millis
        for index in updatedDatabase.cards.indices
        where credentialIDs.contains(updatedDatabase.cards[index].id)
            && !updatedDatabase.cards[index].autofillEnabled {
            updatedDatabase.cards[index].autofillEnabled = true
            updatedDatabase.cards[index].modified = modifiedAt
        }
        database = updatedDatabase
        guard save() else {
            Log.error("autofill", "current vault batch enable failed: local save failed")
            return
        }
        Log.info("autofill", "current vault batch enable completed: changed=\(changedCount)")
        Task { [weak self] in
            guard let self, self.phase == .unlocked else { return }
            guard self.relay.binding(database: self.databaseName) != nil,
                  self.relay.token(database: self.databaseName) != nil else { return }
            _ = await self.sync(auto: true)
        }
    }

    private var saveDebounce: AnyCancellable? = nil
    /// 合并连续编辑，距最后一次调用 600 毫秒后在主 runloop 调用 save。
    ///
    /// 新调用取消之前的待保存订阅；需要立即落盘的边界应显式调用 save。
    func saveDebounced() {
        saveDebounce?.cancel()
        saveDebounce = Just(())
            .delay(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in _ = self?.save() }
    }

    // MARK: - Search (防抖输入,过滤逻辑在 AppContext+CardList)

    /// TextField 绑定入口:记录文本并重排防抖;清空立即生效(列表即时恢复)。
    func setSearchText(_ text: String) {
        searchState.setText(text)
    }

    /// 清空搜索(搜索框 ✕ 按钮):立即生效,不等防抖。
    func clearSearch() {
        searchState.clear()
    }

    // MARK: - Auto-lock (LockedState + auto_lock_setting)

    private func installActivityMonitor() {
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autoLockTick() }
        }
        // 输入、指针移动、点击和滚动都算作活跃操作，不只在切换选中卡片时刷新空闲计时。
        // 本地事件监视器总在主线程触发;直接记录,避免每个按键/滚动事件都
        // 创建一次 Task(高频事件下造成不必要的调度开销)。
        NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.touch() }
            return event
        }
        NSApplication.shared.publisher(for: \.isHidden)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] hidden in
                if hidden == true, self?.settings.lockInBackground == true {
                    Log.info("autolock", "app hidden → locking (lockInBackground)")
                    self?.lock()
                }
            }
            .store(in: &cancellables)
    }

    private func autoLockTick() {
        guard phase == .unlocked, settings.autoLockSeconds > 0 else { return }
        let idle = Date().timeIntervalSince(lastActivity)
        if idle >= Double(settings.autoLockSeconds) {
            Log.info("autolock", "idle \(Int(idle))s ≥ autoLockSeconds=\(settings.autoLockSeconds) → locking")
            lock()
        }
    }

    func touch() { lastActivity = Date() }
}
