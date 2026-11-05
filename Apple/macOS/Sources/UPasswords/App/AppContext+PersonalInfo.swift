import Foundation
import UPasswordsCore

extension AppContext {
    /// 更新当前密码库所有个人资料的加密自动填充设置。
    /// - Parameter enabled: 是否允许注册表单使用已保存的联系信息。
    func setRegistrationAutofillEnabled(_ enabled: Bool) {
        settings.registrationAutofillEnabled = enabled
        for index in database.userProfiles.indices {
            database.userProfiles[index].registrationAutofillEnabled = enabled
            database.userProfiles[index].modified = max(
                Date().millis, database.userProfiles[index].modified + 1
            )
        }
        saveDebounced()
    }

    /// 独立保存个人资料，不将其写入密码卡片。
    /// - Parameter draft: 编辑后的联系信息；内容为空时删除当前资料。
    func savePersonalInfo(_ draft: PersonalInfoDraft) {
        let previous = database.userProfiles.first
        let enabled = previous?.registrationAutofillEnabled ?? settings.registrationAutofillEnabled
        if let profile = draft.makeProfile(autofillEnabled: enabled, updating: previous) {
            if previous != nil {
                database.userProfiles[0] = profile
            } else {
                database.userProfiles.append(profile)
            }
        } else if let previous {
            database.userProfiles.removeAll { $0.id == previous.id }
        }
        saveDebounced()
        Log.info("ui", "personal information saved records=\(database.userProfiles.count)")
    }

    /// 解锁后迁移旧版联系信息卡片，并处理首次设置流程暂存的资料。
    func savePendingPersonalInfoIfNeeded() {
        guard phase == .unlocked else { return }
        if database.migrateLegacyPersonalInfo() > 0 { saveDebounced() }
        guard let draft = pendingPersonalInfo else { return }
        pendingPersonalInfo = nil
        guard database.userProfiles.isEmpty else {
            Log.info("ui", "setup: personal information already exists in restored vault")
            return
        }
        savePersonalInfo(draft)
    }
}
