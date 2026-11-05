import Foundation

/// 侧栏内置分类及其本地化名称、图标和空状态文案。
enum SpecialLabel: String, CaseIterable, Identifiable {
    case allCards = "all_cards_label"
    case favorites = "favorites_label"
    case recent = "recent_label"
    case passwords = "passwords_label"
    case oneTimeCodes = "totp_label"
    case notes = "notes_label"
    case files = "files_label"
    case images = "images_label"
    case passkeys = "passkeys_label"
    case creditCards = "credit_cards_label"
    case weakPasswords = "weak_passwords_label"
    case samePasswords = "same_passwords_label"
    case compromised = "compromised_passwords_label"
    case expiring = "expiring_label"
    case expired = "expired_label"
    case archived = "archived_label"
    case trash = "trash_label"
    case templates = "templates_label"

    var id: String { rawValue }
    var name: String { L10n.db(rawValue) }

    var systemImage: String {
        switch self {
        case .allCards: return "square.grid.2x2"
        case .favorites: return "star.fill"
        case .recent: return "clock"
        case .passwords: return "key"
        case .oneTimeCodes: return "chart.pie.fill"
        case .notes: return "doc.plaintext"
        case .files: return "doc"
        case .images: return "photo"
        case .passkeys: return "person.badge.key.fill"
        case .creditCards: return "creditcard"
        case .weakPasswords: return "xmark.shield"
        case .samePasswords: return "exclamationmark.triangle"
        case .compromised: return "lock.open"
        case .expiring: return "hourglass"
        case .expired: return "hourglass"
        case .archived: return "archivebox"
        case .trash: return "trash"
        case .templates: return "doc.on.doc"
        }
    }

    /// 当前分类空状态提示对应的本地化文案。
    var emptyState: String {
        switch self {
        case .allCards: return L10n.t("user_empty_state")
        case .favorites: return L10n.t("favorites_empty_state")
        case .recent: return L10n.t("recent_empty_state")
        case .passkeys: return L10n.t("passkeys_empty_state")
        case .notes: return L10n.t("notes_empty_state")
        case .compromised: return L10n.t("compromised_passwords_empty_state")
        case .weakPasswords: return L10n.t("weak_passwords_empty_state")
        case .expired: return L10n.t("expired_empty_state")
        case .expiring: return L10n.t("expiring_empty_state")
        case .archived: return L10n.t("archived_empty_state")
        case .trash: return L10n.t("trash_empty_state")
        case .templates: return L10n.t("templates_empty_state")
        default: return L10n.t("user_empty_state")
        }
    }
}

import SwiftUI
import UPasswordsCore
import UPasswordsNetworking

/// 侧栏当前选择：内置分类或用户创建的标签。
enum SidebarSelection: Hashable {
    case special(SpecialLabel)
    case label(UUID)
}

/// 卡片排序方式；原始值对应本地化资源中的排序键。
enum Sorting: String, CaseIterable, Identifiable {
    case titleAsc = "title_asc"
    case titleDesc = "title_desc"
    case websiteAsc = "website_asc"
    case websiteDesc = "website_desc"
    case createdAsc = "created_asc"
    case createdDesc = "created_desc"
    case modifiedAsc = "modified_asc"
    case modifiedDesc = "modified_desc"
    case sizeAsc = "size_asc"
    case sizeDesc = "size_desc"

    var id: String { rawValue }
    var name: String { L10n.t("\(rawValue)_text") }

    func sort(_ cards: [Card], favoritesFirst: Bool) -> [Card] {
        var out = cards
        switch self {
        case .titleAsc: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .websiteAsc:
            out.sort { websiteValue(for: $0).localizedCaseInsensitiveCompare(websiteValue(for: $1)) == .orderedAscending }
        case .websiteDesc:
            out.sort { websiteValue(for: $0).localizedCaseInsensitiveCompare(websiteValue(for: $1)) == .orderedDescending }
        case .createdAsc: out.sort { $0.created < $1.created }
        case .createdDesc: out.sort { $0.created > $1.created }
        case .modifiedAsc: out.sort { $0.modified < $1.modified }
        case .modifiedDesc: out.sort { $0.modified > $1.modified }
        case .sizeAsc: out.sort { $0.size < $1.size }
        case .sizeDesc: out.sort { $0.size > $1.size }
        }
        if favoritesFirst {
            out.sort { $0.favorite && !$1.favorite }
        }
        return out
    }

    private func websiteValue(for card: Card) -> String {
        card.fields.first { $0.type == .website }?.value ?? ""
    }
}

/// 数据文件中卡片颜色属性所使用的固定词汇表。
enum CardColor: String, CaseIterable, Identifiable {
    case gray, blue, red, green, yellow, purple, orange, cyan, pink, brown, white, black
    var id: String { rawValue }
}
