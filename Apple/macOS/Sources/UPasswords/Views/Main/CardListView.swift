import SwiftUI
import UPasswordsCore

// MARK: - Card list (邮件消息列表式:标题+日期一行 / 副标题+角标一行,
// 搜索与同步已上移到顶部工具栏,列表栏只承载纯列表)

/// 按筛选和搜索状态组织卡片列表，将用户动作交给会话层。
struct CardListView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject private var searchResults: AppContext.SearchState.Results

    /// 最近一次非空选中项:删除动作会先把 selectedCardId 置 nil,
    /// 补选相邻项时需用它还原「被移除的是谁」。
    @State private var lastSelectedID: UUID?

    var body: some View {
        let visibleCards = cards
        return list(visibleCards)
            .background(Color.appBackground)
            .overlay {
                if visibleCards.isEmpty {
                    emptyState
                }
            }
    }

    private var cards: [Card] {
        ctx.cards(for: ctx.selection, search: searchResults.query)
    }

    private func list(_ cards: [Card]) -> some View {
        let previewWord = searchResults.query
            .split(separator: " ")
            .first
            .map(String.init)

        return List(selection: $ctx.selectedCardId) {
            ForEach(cards) { card in
                CardListCellView(
                    card: card,
                    preview: previewWord.flatMap { ctx.searchPreview(for: card, word: $0) })
                    .tag(card.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .frame(height: 50)
                    .contextMenu {
                        cardContextMenu(card)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focusable()
        .onKeyPress(.delete) {
            guard let id = ctx.selectedCardId else { return .ignored }
            ctx.deleteCard(id)
            return .handled
        }
        .onAppear {
            // 进入主界面后始终有选中项
            if ctx.selectedCardId == nil { ctx.selectedCardId = cards.first?.id }
        }
        .onChange(of: ctx.selectedCardId) { _, id in
            if let id {
                lastSelectedID = id
                ctx.pushRecent(id)
                ctx.touch()
            }
        }
        .onChange(of: cards.map(\.id)) { oldIDs, newIDs in
            reselectNeighbor(oldIDs: oldIDs, newIDs: newIDs)
        }
    }

    /// 选中项离开可见列表(删除/切分类/搜索过滤)后补选相邻项:
    /// 详情面板不再悬空展示不在当前列表中的卡片,连续 Delete 也不中断。
    private func reselectNeighbor(oldIDs: [UUID], newIDs: [UUID]) {
        let removed = ctx.selectedCardId ?? lastSelectedID
        guard let removed, !newIDs.contains(removed) else { return }
        let neighbor: UUID?
        if let index = oldIDs.firstIndex(of: removed) {
            neighbor = index < newIDs.count ? newIDs[index] : newIDs.last
        } else {
            neighbor = newIDs.first
        }
        ctx.selectedCardId = neighbor
        Log.info("ui", "list reselect after removal old=\(removed) new=\(neighbor.map { "\($0)" } ?? "nil") visible=\(newIDs.count)")
    }

    /// 列表右键菜单。
    @ViewBuilder
    private func cardContextMenu(_ card: Card) -> some View {
        Button(L10n.t("add_card_command")) { ctx.activeSheet = .addCard }
        Button(L10n.t("add_note_command")) { ctx.activeSheet = .addNote }
        Button(L10n.t("add_template_command")) { ctx.activeSheet = .addCard }
        Divider()
        Button(
            L10n.t(card.trashed ? "ios_purge_button" : "delete_command"),
            role: .destructive
        ) {
            ctx.deleteCard(card.id)
        }
        Button(L10n.t("move_command")) { ctx.activeSheet = .labels(cardId: card.id) }
        Button(L10n.t("duplicate_command")) { ctx.duplicateCard(card.id) }
        Button(L10n.t("save_as_template_command")) {
            ctx.saveAsTemplate(from: card)
        }
        if card.archived {
            Button(L10n.t("unarchive_command")) { ctx.unarchiveCard(card.id) }
        } else {
            Button(L10n.t("archive_command")) { ctx.archiveCard(card.id) }
        }
        if card.trashed {
            Button(L10n.t("restore_card_command")) { ctx.restoreCard(card.id) }
        }
        Divider()
        Button(L10n.t("copy_as_text_command")) {
            ClipboardModel.shared.copy(card.asPlainText())
        }
        Menu(L10n.t("share_menu")) {
            Button(L10n.t("export_command")) { ctx.activeSheet = .exportAs }
        }
        Divider()
        Button(L10n.t("set_labels_command")) { ctx.activeSheet = .labels(cardId: card.id) }
        Button(L10n.t("use_website_icon_command")) {
            ctx.toggleUseWebsiteIcon(cardId: card.id)
        }
        Button(L10n.t("select_symbol_command")) { ctx.activeSheet = .selectSymbol(cardId: card.id) }
        Button(L10n.t("select_color_command")) { ctx.activeSheet = .selectColor(cardId: card.id) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(emptyStateText)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
        }
        .padding()
    }

    private var emptyStateText: String {
        switch ctx.selection {
        case .special(let sp): return sp.emptyState
        case .label: return L10n.t("user_empty_state")
        }
    }
}

/// 邮件消息列表式单元格 — 32pt 圆形图标居左,第一行「标题 + 徽标 + 日期」,
/// 第二行「副标题 + 角标(一次性代码/收藏)」;选中行文字反白。
struct CardListCellView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let card: Card
    let preview: String?

    var body: some View {
        let selected = ctx.selectedCardId == card.id
        HStack(spacing: 0) {
            CardIconView(symbol: card.symbol, color: card.color, size: 32,
                         creditCardNumber: card.fields.first { $0.type == .number }?.value,
                         card: card)
                .padding(.leading, 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(card.title.isEmpty ? "—" : card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .lineLimit(1)
                    if card.isExpired {
                        Image(systemName: "clock.badge.exclamationmark").font(.caption2).foregroundStyle(.red)
                    } else if card.isExpiring {
                        Image(systemName: "hourglass").font(.caption2).foregroundStyle(.orange)
                    }
                    if card.hasWeakPasswords {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                    }
                    Spacer(minLength: 8)
                    Text(dateText)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.white.opacity(0.42))
                }
                HStack(spacing: 4) {
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? Color.white.opacity(0.72) : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        if card.fields.contains(where: { $0.type == .oneTimePassword }) {
                            Image(systemName: "timer")
                                .font(.system(size: 11))
                                .foregroundStyle(selected ? Color.white : .blue)
                        }
                        Button {
                            ctx.toggleFavorite(card.id)
                        } label: {
                            Image(systemName: card.favorite ? "star.fill" : "star")
                                .font(.system(size: 11))
                                .foregroundStyle(card.favorite ? .yellow
                                                 : selected ? Color.white.opacity(0.45)
                                                 : Color.secondary.opacity(0.4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
        }
        .frame(height: 50)
        .contentShape(Rectangle())
    }

    /// 右上角日期:相对当日显示「今天/昨天」,否则为缩写日期(邮件列表惯例)。
    private var dateText: String {
        let modified = card.modified.date
        if Calendar.current.isDateInToday(modified) { return L10n.t("date_today_text") }
        if Calendar.current.isDateInYesterday(modified) { return L10n.t("date_yesterday_text") }
        return modified.formatted(date: .abbreviated, time: .omitted)
    }

    private var subtitle: String {
        if let preview { return preview }
        if card.login.isEmpty {
            return card.fields.first(where: { $0.hasValue })?.value ?? ""
        }
        return card.login
    }
}
