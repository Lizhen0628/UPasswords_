import Foundation
import UPasswordsNetworking

/// 弹层路由目录；关联值携带标签、卡片等目标标识。
/// 具体视图映射统一登记在 `Views/Sheets/SheetFactory.swift`。
enum AppSheet: Identifiable, Hashable {
    case addCard            // 添加项目
    case addNote            // 添加笔记
    case addLabel
    case editCardLabel(id: UUID) // rename_label_title
    case selectColorCardLabel(id: UUID) // 标签颜色选择
    case sorting
    case generator
    case labels(cardId: UUID)
    case selectSymbol(cardId: UUID)
    case selectColor(cardId: UUID) // 卡片颜色选择(列表右键,结果直接写卡)
    case selectTexture
    case selectTemplate     // template picker inside edit-card
    case passwordHistory    // password_history_command
    case exportAs
    case importData
    case databaseInfo
    case personalInfo
    case compromised
    case changePassword
    case configureCloud
    case eraseData          // 擦除数据 confirm
    case manageDatabases
    case importCards(sourceName: String, destinationName: String)
    case selectDatabase
    case preferences        // 设置 window
    case about
    case whatsNew
    case premium
    case setupPlan
    case expiredCards       // expiring_cards_warning prompt
    case restoreTemplates   // restore_templates_query

    var id: String {
        switch self {
        case .addCard: return "addCard"
        case .addNote: return "addNote"
        case .addLabel: return "addLabel"
        case .editCardLabel(let id): return "editLabel:\(id)"
        case .selectColorCardLabel(let id): return "selectColorLabel:\(id)"
        case .sorting: return "sorting"
        case .generator: return "generator"
        case .labels(let id): return "labels:\(id)"
        case .selectSymbol(let id): return "selectSymbol:\(id)"
        case .selectColor(let id): return "selectColor:\(id)"
        case .selectTexture: return "selectTexture"
        case .selectTemplate: return "selectTemplate"
        case .passwordHistory: return "passwordHistory"
        case .exportAs: return "exportAs"
        case .importData: return "importData"
        case .databaseInfo: return "databaseInfo"
        case .personalInfo: return "personalInfo"
        case .compromised: return "compromised"
        case .changePassword: return "changePassword"
        case .configureCloud: return "configureCloud"
        case .eraseData: return "eraseData"
        case .manageDatabases: return "manageDatabases"
        case .importCards(let sourceName, let destinationName):
            return "importCards:\(sourceName):\(destinationName)"
        case .selectDatabase: return "selectDatabase"
        case .preferences: return "preferences"
        case .about: return "about"
        case .whatsNew: return "whatsNew"
        case .premium: return "premium"
        case .setupPlan: return "setupPlan"
        case .expiredCards: return "expiredCards"
        case .restoreTemplates: return "restoreTemplates"
        }
    }

    /// 由编辑表单内打开、编辑表单关闭时应当一并关闭的弹层
    /// (否则会残留成孤儿弹层,其 OK 还可能错写下一个打开的编辑草稿)。
    /// 颜色/符号选择已改为携带目标卡片直接写库,不再依赖编辑草稿。
    var isEditSheetContext: Bool {
        switch self {
        case .selectTemplate:
            return true
        default:
            return false
        }
    }
}
