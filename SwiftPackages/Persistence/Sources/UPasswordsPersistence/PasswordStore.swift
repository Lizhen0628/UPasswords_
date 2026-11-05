import Foundation
import Security
import LocalAuthentication
import UPasswordsCore

/// Per-database keychain storage, with an optional biometry-protected entry
/// for fast unlock (Touch ID).
public enum PasswordStore {
    #if os(macOS)
    /// The credential provider's shared group from the current signed process.
    public static var credentialProviderAccessGroup: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task, "keychain-access-groups" as CFString, nil) as? [String] else {
            return nil
        }
        return groups.first { $0.hasSuffix(".com.upasswords.shared") }
    }
    #endif
    /// 派生指定库使用的钥匙串 service 名称。
    ///
    /// - Parameter name: 本地库名。
    /// - Returns: 与现有钥匙串记录兼容的 service 标识。
    public static func service(forDatabaseName name: String) -> String { "UPasswords-\(name)" }

    /// 保存普通密码钥匙串副本，失败通过安全日志报告。
    ///
    /// - Parameters:
    ///   - password: 本地库主密码。
    ///   - databaseName: 本地库名。
    public static func savePassword(_ password: String, databaseName: String) {
        save(password: password, account: "database", databaseName: databaseName)
    }

    /// 测试缝隙:CI 无密码锁/生物识别,强制走普通项路径保证确定性。
    static var usePlainBiometricItemsForTesting = false

    /// Biometry-gated copy of the database password.
    ///
    /// 双层门禁:优先存 kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly +
    /// SecAccessControl(.userPresence) 项——读取必须过系统生物识别(硬件层),
    /// 配合 kSecUseAuthenticationContext 复用调用方已评估的 LAContext,
    /// 全程只弹一次。设备未设密码锁或未正确签名(SecItemAdd 失败,如 -34018)
    /// 时回退普通项,由 evaluatePolicy 做唯一门禁(历史行为)。
    /// - Parameters:
    ///   - password: The local database master password.
    ///   - databaseName: The local database name.
    ///   - sharedAccessGroup: Optional shared Data Protection Keychain group. When supplied,
    ///     the shared item is the sole biometric copy; the legacy local-keychain item is not written.
    public static func savePasswordForBiometric(
        _ password: String,
        databaseName: String,
        sharedAccessGroup: String? = nil
    ) {
        if let sharedAccessGroup {
            _ = saveSharedBiometricPassword(
                password,
                databaseName: databaseName,
                accessGroup: sharedAccessGroup)
            return
        }
        if !usePlainBiometricItemsForTesting, saveSecured(password: password, databaseName: databaseName) {
            return
        }
        save(password: password, account: "biometric", databaseName: databaseName)
    }

    /// Saves a biometric-protected password copy in an explicitly shared keychain group.
    /// Unlike the legacy local item, this never falls back to an unprotected entry.
    ///
    /// - Parameters:
    ///   - password: The database master password.
    ///   - databaseName: The local database name.
    ///   - accessGroup: A keychain access group shared with the credential provider.
    @discardableResult
    public static func saveSharedBiometricPassword(
        _ password: String,
        databaseName: String,
        accessGroup: String
    ) -> Bool {
        guard !usePlainBiometricItemsForTesting,
              saveSecured(password: password, databaseName: databaseName, accessGroup: accessGroup) else {
            Log.error("keychain", "shared biometric item unavailable for \(service(forDatabaseName: databaseName))")
            return false
        }
        guard hasBiometricItem(databaseName: databaseName, accessGroup: accessGroup) else {
            Log.error("keychain", "shared biometric item verification failed for \(service(forDatabaseName: databaseName))")
            return false
        }
        Log.info("keychain", "shared biometric item saved for \(service(forDatabaseName: databaseName))")
        return true
    }

    /// 带 userPresence ACL 的加固项;成功返回 true。
    private static func saveSecured(
        password: String,
        databaseName: String,
        accessGroup: String? = nil
    ) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if accessGroup == nil {
            SecItemDelete(query as CFDictionary)
        }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            // 未设密码锁等场景:创建失败走普通项回退
            Log.warn("keychain", "secured biometric item unavailable (\(accessError?.takeRetainedValue().localizedDescription ?? "unknown"))")
            return false
        }
        var attrs = query
        attrs[kSecValueData as String] = Data(password.utf8)
        attrs[kSecAttrAccessControl as String] = access
        var status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem, accessGroup != nil {
            status = SecItemUpdate(query as CFDictionary, [
                kSecValueData as String: Data(password.utf8),
            ] as CFDictionary)
        }
        if status == errSecSuccess {
            Log.info("keychain", "secured biometric item saved for \(service(forDatabaseName: databaseName)) (userPresence ACL)")
            return true
        }
        Log.logKeychain("save secured biometric item", status: status)
        return false
    }

    /// 写入钥匙串密码副本的共用实现(普通项与生物识别项仅 account 不同)。
    private static func save(password: String, account: String, databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(password.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        Log.logKeychain("save \"\(account)\" for \(service(forDatabaseName: databaseName))", status: status)
    }

    /// 移除库的钥匙串密码副本(数据库项与生物识别项)。
    /// 他机改密后强制锁定时调用:清掉旧密码副本,避免锁屏预填/生物识别
    /// 用旧密码误导用户;重新解锁成功后由解锁路径自愈回写新密码。
    public static func removePassword(databaseName: String, sharedAccessGroup: String? = nil) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
        ]
        for account in ["database", "biometric"] {
            var query = base
            query[kSecAttrAccount as String] = account
            SecItemDelete(query as CFDictionary)
        }
        if let sharedAccessGroup {
            var query = base
            query[kSecAttrAccount as String] = "biometric"
            query[kSecAttrAccessGroup as String] = sharedAccessGroup
            query[kSecUseDataProtectionKeychain as String] = true
            SecItemDelete(query as CFDictionary)
        }
        Log.logKeychain("remove password copies for \(service(forDatabaseName: databaseName))", status: errSecSuccess)
    }

    /// Checks for a biometric password copy without presenting authentication UI.
    ///
    /// Protected items return `errSecInteractionNotAllowed` when UI is disabled;
    /// that status confirms the item exists but requires authentication to read.
    /// - Parameters:
    ///   - databaseName: The local database name.
    ///   - accessGroup: Optional shared keychain access group to check.
    /// - Returns: Whether the biometric password copy exists.
    public static func hasBiometricItem(databaseName: String, accessGroup: String? = nil) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
            kSecUseAuthenticationContext as String: context,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        let exists = status == errSecSuccess || status == errSecInteractionNotAllowed
        Log.debug(
            "keychain",
            "hasBiometricItem \(service(forDatabaseName: databaseName)) status=\(status) exists=\(exists)")
        return exists
    }

    /// Prompts Touch ID, then (on success) returns the stored database password
    /// via `completion`. `completion` is called on an arbitrary queue.
    /// - Parameters:
    ///   - databaseName: The local database name.
    ///   - accessGroup: Optional group containing the protected keychain item.
    ///   - context: Optional context already paired with an embedded authentication view.
    ///   - completion: Receives the password or `nil` after cancellation or failure.
    public static func biometricPassword(
        databaseName: String,
        accessGroup: String? = nil,
        context: LAContext? = nil,
        completion: @escaping (String?) -> Void
    ) {
        let ctx = context ?? LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            Log.warn("keychain", "biometric unavailable: \(err?.localizedDescription ?? "unknown")")
            completion(nil)
            return
        }
        Log.debug("keychain", "evaluating Touch ID policy")
        ctx.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: L10n.t("touch_id_unlock_reason")
        ) { ok, error in
            if ok {
                Log.debug("keychain", "Touch ID ok → reading password copy")
                // Preserve the existing non-embedded flow for callers that don't supply
                // a context paired with LAAuthenticationView.
                if context == nil, accessGroup == nil,
                   let plain = loadPassword(databaseName: databaseName) {
                    completion(plain)
                    return
                }
                // Prefer the ACL-protected copy when an embedded context is supplied.
                if let protected = loadPassword(
                    databaseName: databaseName,
                    biometric: true,
                    context: ctx,
                    accessGroup: accessGroup) {
                    completion(protected)
                    return
                }
                if accessGroup == nil {
                    completion(loadPassword(databaseName: databaseName))
                } else {
                    completion(nil)
                }
            } else {
                Log.warn("keychain", "Touch ID denied: \(error?.localizedDescription ?? "unknown")")
                completion(nil)
            }
        }
    }

    /// - Parameter context: 已通过 evaluatePolicy 的 LAContext;带 ACL 的
    ///   biometric 项必须凭它静默读取(否则 errSecInteractionNotAllowed)。
    public static func loadPassword(
        databaseName: String,
        biometric: Bool = false,
        context: LAContext? = nil,
        accessGroup: String? = nil
    ) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: biometric ? "biometric" : "database",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        let account = biometric ? "biometric" : "database"
        guard status == errSecSuccess, let data = out as? Data else {
            Log.warn("keychain", "load \"\(account)\" for \(service(forDatabaseName: databaseName)) failed (OSStatus \(status))")
            return nil
        }
        Log.debug("keychain", "load \"\(account)\" for \(service(forDatabaseName: databaseName)) ok (\(data.count) chars)")
        return String(data: data, encoding: .utf8)
    }

    /// 检查设备当前是否支持生物识别认证。
    ///
    /// - Returns: LocalAuthentication 的能力检查结果；不代表已有本库密码项。
    public static func biometricAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// 移除指定库的生物识别钥匙串副本。
    ///
    /// - Parameters:
    ///   - databaseName: 本地库名；不会删除普通密码副本。
    ///   - sharedAccessGroup: Optional shared group whose biometric copy is also removed.
    public static func removeBiometricPassword(
        databaseName: String,
        sharedAccessGroup: String? = nil
    ) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
        ]
        let localStatus = SecItemDelete(query as CFDictionary)
        Log.debug("keychain", "removeBiometricPassword \(service(forDatabaseName: databaseName)) (OSStatus \(localStatus))")
        guard let sharedAccessGroup else { return }
        query[kSecAttrAccessGroup as String] = sharedAccessGroup
        query[kSecUseDataProtectionKeychain as String] = true
        let sharedStatus = SecItemDelete(query as CFDictionary)
        Log.debug("keychain", "remove shared biometric item for \(service(forDatabaseName: databaseName)) (OSStatus \(sharedStatus))")
    }

    /// eraseDataForDatabaseName:
    public static func eraseData(databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
        ]
        let status = SecItemDelete(query as CFDictionary)
        Log.debug("keychain", "eraseData \(service(forDatabaseName: databaseName)) (OSStatus \(status))")
    }
}

extension Log {
    /// 钥匙串错误码统一翻译,常用的直接给含义(OSStatus 码难记)。
    public static func logKeychain(_ what: String, status: OSStatus) {
        if status == errSecSuccess {
            info("keychain", "\(what) ok")
            return
        }
        let meaning: String
        switch status {
        case errSecItemNotFound: meaning = "item not found"
        case errSecDuplicateItem: meaning = "duplicate item"
        case errSecInteractionNotAllowed: meaning = "interaction not allowed (locked keychain / ACL)"
        case -34018: meaning = "missing entitlement (app not properly signed)"
        default: meaning = "see Security framework docs"
        }
        error("keychain", "\(what) FAILED (OSStatus \(status): \(meaning))")
    }
}
