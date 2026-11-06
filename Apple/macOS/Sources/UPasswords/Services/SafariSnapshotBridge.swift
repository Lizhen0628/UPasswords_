import Foundation

import UPasswordsCore
import UPasswordsPersistence

/// 把 SwiftData 当前库加密后推送到 App Group，供 Safari 和凭据扩展读取。
enum SafariSnapshotBridge {
    private static let appGroup = "2CV6VKVD26.com.upasswords.shared"
    private static let credentialProviderDirectory = "CredentialProvider"
    private static let safariDirectory = "Safari"

    enum CleanupError: Error {
        case groupUnavailable
    }

    /// 推送当前库密文与信封快照。失败只记日志，不打扰主流程。
    /// - Parameters:
    ///   - name: 当前库名
    ///   - encryptedBody: 当前数据库加密容器。
    ///   - envelope: 用主密码包裹的库密钥。
    static func push(databaseName name: String, encryptedBody: Data, envelope: Data) {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            Log.warn("chrome", "shared snapshot skipped: app group unavailable")
            return
        }
        let dir = group.appendingPathComponent(safariDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encryptedBody.write(to: dir.appendingPathComponent("\(name).upw"), options: .atomic)
            try envelope.write(to: dir.appendingPathComponent("\(name).upwkey"), options: .atomic)
            try Data(name.utf8).write(to: dir.appendingPathComponent("current"), options: .atomic)

            let credentialProviderRoot = group.appendingPathComponent(
                credentialProviderDirectory, isDirectory: true)
            let credentialProviderDatabases = credentialProviderRoot.appendingPathComponent(
                "Databases", isDirectory: true)
            try FileManager.default.createDirectory(
                at: credentialProviderDatabases, withIntermediateDirectories: true)
            try encryptedBody.write(
                to: credentialProviderDatabases.appendingPathComponent("\(name).upw"),
                options: .atomic)
            try envelope.write(
                to: credentialProviderDatabases.appendingPathComponent("\(name).upwkey"),
                options: .atomic)
            try Data(name.utf8).write(
                to: credentialProviderRoot.appendingPathComponent("current"), options: .atomic)
            Log.debug("chrome", "safari snapshot pushed: \(name) (\(encryptedBody.count)B)")
        } catch {
            Log.warn("chrome", "safari snapshot push failed for \(name): \(error)")
        }
    }

    /// 删除两个扩展的共享快照；其中一个删除失败时仍会继续尝试另一个。
    /// - Throws: 共享容器不可用或快照删除失败时抛出错误。
    static func removeSnapshots() throws {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup) else {
            throw CleanupError.groupUnavailable
        }
        try removeSnapshots(in: group)
    }

    /// 在指定的共享容器目录中删除扩展快照。
    /// - Parameters:
    ///   - group: 共享容器根目录。
    ///   - removeItem: 文件删除操作，供错误路径测试注入。
    /// - Throws: 两个目录均尝试删除后，若有失败则抛出首个错误。
    static func removeSnapshots(
        in group: URL,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        var firstError: Error?
        for directory in [safariDirectory, credentialProviderDirectory] {
            do {
                try removeItem(group.appendingPathComponent(directory, isDirectory: true))
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                continue
            } catch {
                Log.error("db", "shared snapshot removal failed for \(directory): \(error)")
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        Log.info("db", "shared extension snapshots removed")
    }
}
