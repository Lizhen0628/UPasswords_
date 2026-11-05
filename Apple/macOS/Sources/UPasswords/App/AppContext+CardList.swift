import Foundation
import UPasswordsCore
import UPasswordsNetworking

/// 按侧栏选择派生卡片列表，并管理搜索与最近打开的卡片身份。
extension AppContext {

    // MARK: - Selection

    var selectedCard: Card? {
        selectedCardId.flatMap { database.card(id: $0) }
    }

    // MARK: - Recent (RecentModel)

    private static let recentKey = "recent.cardIds"
    /// 最近打开列表容量上限(超出淘汰最旧条目)
    private static let recentLimit = 20

    var recentIds: [UUID] {
        (UserDefaults.standard.array(forKey: Self.recentKey) as? [String] ?? []).compactMap(UUID.init(uuidString:))
    }

    func pushRecent(_ cardId: UUID) {
        var ids = (UserDefaults.standard.array(forKey: Self.recentKey) as? [String] ?? []).compactMap(UUID.init(uuidString:))
        ids.removeAll { $0 == cardId }
        ids.insert(cardId, at: 0)
        if ids.count > Self.recentLimit { ids.removeLast(ids.count - Self.recentLimit) }
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: Self.recentKey)
        recentRevision &+= 1
        updateRecentSidebarCount()
        Log.info("ui", "pushRecent cardId=\(cardId) total=\(ids.count)")
        objectWillChange.send()
    }

    func clearRecent() {
        Log.info("ui", "clearRecent (had \(recentIds.count))")
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
        recentRevision &+= 1
        updateRecentSidebarCount()
        objectWillChange.send()
    }

    // MARK: - Card list strategies

    /// The card list for the current sidebar selection + search.
    func cards(for selection: SidebarSelection, search: String) -> [Card] {
        let filterKey = cardFilterCacheKey(for: selection, search: search)
        let filteredIDs = filteredCardIDs(for: filterKey)
        let sortKey = CardSortCacheKey(
            filter: filterKey,
            sorting: settings.sorting,
            favoritesFirst: settings.favoritesAtTop
        )
        if sortedCardIDsCacheKey != sortKey {
            let filteredCards = filteredIDs.compactMap { id in
                cardIndexByID[id].map { database.cards[$0] }
            }
            sortedCardIDsCache = settings.sortingValue
                .sort(filteredCards, favoritesFirst: settings.favoritesAtTop)
                .map(\.id)
            sortedCardIDsCacheKey = sortKey
        }
        return sortedCardIDsCache.compactMap { id in
            cardIndexByID[id].map { database.cards[$0] }
        }
    }

    /// 过滤但未排序的列表。计数场景(侧栏角标)不必付出排序开销。
    private func filteredCards(for selection: SidebarSelection, search: String) -> [Card] {
        let searchWords = search.lowercased()
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var cards: [Card]
        switch selection {
        case .special(let sp):
            cards = strategyCards(for: sp)
        case .label(let labelId):
            cards = database.activeCards.filter { $0.labelIds.contains(labelId) && !$0.archived }
        }
        if !searchWords.isEmpty {
            cards = cards.filter { satisfiesSearch($0, words: searchWords) }
        }
        return cards
    }

    private func cardFilterCacheKey(
        for selection: SidebarSelection,
        search: String
    ) -> CardFilterCacheKey {
        let selectionUsesRecentOrder: Bool
        if case .special(.recent) = selection {
            selectionUsesRecentOrder = true
        } else {
            selectionUsesRecentOrder = false
        }
        return CardFilterCacheKey(
            databaseRevision: databaseRevision,
            recentRevision: selectionUsesRecentOrder ? recentRevision : 0,
            selection: selection,
            search: search,
            searchByLabels: settings.searchByLabels,
            searchPasswords: settings.searchPasswords
        )
    }

    private func filteredCardIDs(for key: CardFilterCacheKey) -> [UUID] {
        guard filteredCardIDsCacheKey != key else { return filteredCardIDsCache }
        filteredCardIDsCache = filteredCards(for: key.selection, search: key.search).map(\.id)
        filteredCardIDsCacheKey = key
        return filteredCardIDsCache
    }

    private func strategyCards(for sp: SpecialLabel) -> [Card] {
        let active = database.activeCards
        switch sp {
        case .allCards:
            return active.filter { !$0.archived }
        case .favorites:
            return active.filter { $0.favorite && !$0.archived }
        case .recent:
            let ids = recentIds
            return ids.compactMap { id in active.first { $0.id == id } }
        case .passwords:
            return active.filter { !$0.archived && $0.fields.contains { $0.type == .password } }
        case .oneTimeCodes:
            return active.filter { !$0.archived && $0.fields.contains { $0.type == .oneTimePassword } }
        case .notes:
            return active.filter { !$0.archived && $0.hasNotes && $0.fields.allSatisfy { !$0.type.isLogin && $0.type != .password } }
        case .files:
            return active.filter { !$0.archived && $0.hasFiles }
        case .images:
            return active.filter { !$0.archived && $0.hasImages }
        case .passkeys:
            return [] // passkeys are created in the mobile version (passkeys_empty_state)
        case .creditCards:
            return active.filter { !$0.archived && $0.symbol == "credit_card" }
        case .weakPasswords:
            return active.filter { !$0.archived && $0.hasWeakPasswords }
        case .samePasswords:
            return active.filter { reusedPasswordCardIDs.contains($0.id) }
        case .compromised:
            return active.filter { !$0.archived && $0.compromised }
        case .expiring:
            return active.filter { !$0.archived && !$0.trashed && $0.isExpiring }
        case .expired:
            return active.filter { !$0.archived && !$0.trashed && $0.isExpired }
        case .archived:
            return active.filter { $0.archived }
        case .trash:
            return database.cards.filter { $0.trashed }
        case .templates:
            return database.templateCards.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    /// Sidebar badge count snapshot, refreshed once per database change or calendar day.
    func sidebarCount(for selection: SidebarSelection) -> Int {
        let now = Date()
        guard sidebarCountsAreCurrent,
              Calendar.current.isDate(sidebarCountsCalculatedAt, inSameDayAs: now) else {
            refreshSidebarCounts(now: now)
            return sidebarCardCounts[selection] ?? 0
        }
        return sidebarCardCounts[selection] ?? 0
    }

    /// 计数场景(工具栏副标题):当前选择 + 搜索词,只过滤不排序。
    func count(for selection: SidebarSelection, search: String) -> Int {
        filteredCardIDs(for: cardFilterCacheKey(for: selection, search: search)).count
    }

    private func refreshSidebarCounts(now: Date) {
        var counts: [SidebarSelection: Int] = [:]
        var activeCardIDs = Set<UUID>()

        for card in database.cards {
            if card.template {
                counts[.special(.templates), default: 0] += 1
            }
            if card.trashed {
                counts[.special(.trash), default: 0] += 1
                continue
            }
            guard !card.template else { continue }

            activeCardIDs.insert(card.id)
            if reusedPasswordCardIDs.contains(card.id) {
                counts[.special(.samePasswords), default: 0] += 1
            }
            if card.archived {
                counts[.special(.archived), default: 0] += 1
                continue
            }

            counts[.special(.allCards), default: 0] += 1
            if card.favorite {
                counts[.special(.favorites), default: 0] += 1
            }
            if card.hasWeakPasswords {
                counts[.special(.weakPasswords), default: 0] += 1
            }
            if card.compromised {
                counts[.special(.compromised), default: 0] += 1
            }
            if card.isExpiring {
                counts[.special(.expiring), default: 0] += 1
            }
            if card.isExpired {
                counts[.special(.expired), default: 0] += 1
            }
            if card.symbol == "credit_card" {
                counts[.special(.creditCards), default: 0] += 1
            }
            if card.hasFiles {
                counts[.special(.files), default: 0] += 1
            }
            if card.hasImages {
                counts[.special(.images), default: 0] += 1
            }

            var hasPassword = false
            var hasOneTimePassword = false
            var hasOnlyNotes = card.hasNotes
            for field in card.fields {
                if field.type == .password {
                    hasPassword = true
                    hasOnlyNotes = false
                }
                if field.type == .oneTimePassword {
                    hasOneTimePassword = true
                }
                if field.type.isLogin {
                    hasOnlyNotes = false
                }
            }
            if hasPassword {
                counts[.special(.passwords), default: 0] += 1
            }
            if hasOneTimePassword {
                counts[.special(.oneTimeCodes), default: 0] += 1
            }
            if hasOnlyNotes {
                counts[.special(.notes), default: 0] += 1
            }
            for labelID in Set(card.labelIds) {
                counts[.label(labelID), default: 0] += 1
            }
        }

        counts[.special(.recent)] = recentIds.filter(activeCardIDs.contains).count
        sidebarCardCounts = counts
        sidebarActiveCardIDs = activeCardIDs
        sidebarCountsCalculatedAt = now
        sidebarCountsAreCurrent = true
    }

    private func updateRecentSidebarCount() {
        guard sidebarCountsAreCurrent,
              Calendar.current.isDate(sidebarCountsCalculatedAt, inSameDayAs: Date()) else {
            sidebarCountsAreCurrent = false
            return
        }
        sidebarCardCounts[.special(.recent)] = recentIds.filter(sidebarActiveCardIDs.contains).count
    }

    // MARK: - Search (XCard.satisfiesToSearchWords / previewForSearchWords)

    /// XCard.satisfiesToSearchWords:labelNames: — every word must hit title,
    /// field name/value, notes or label names; passwords optionally included.
    private func satisfiesSearch(_ card: Card, words: [String]) -> Bool {
        words.allSatisfy { containsWord(card, word: $0) }
    }

    private func containsWord(_ card: Card, word: String) -> Bool {
        if matchesSearchTerm(word, in: card.title) { return true }
        if matchesSearchTerm(word, in: card.notes) { return true }
        for f in card.fields {
            if matchesSearchTerm(word, in: f.name) { return true }
            if f.type.isSearchable {
                if !f.type.isHidden || settings.searchPasswords {
                    if matchesSearchTerm(word, in: f.value) { return true }
                } else if matchesSearchTerm(word, in: f.value) {
                    return true // hidden fields match on value but not shown in preview
                }
            }
        }
        if settings.searchByLabels {
            for lid in card.labelIds {
                if let label = database.label(id: lid), matchesSearchTerm(word, in: label.name) { return true }
            }
        }
        return false
    }

    private func matchesSearchTerm(_ word: String, in text: String) -> Bool {
        text.range(of: word, options: .caseInsensitive) != nil
    }

    /// XCard.previewForSearchWords — the "title — matched snippet" row preview.
    func searchPreview(for card: Card, word: String) -> String? {
        let w = word.lowercased()
        for f in card.fields where f.type.isSearchable {
            if !f.type.isHidden || settings.searchPasswords {
                if matchesSearchTerm(w, in: f.value) {
                    return "\(f.name): …\(snippet(f.value, around: w))…"
                }
            }
        }
        if matchesSearchTerm(w, in: card.notes) {
            return "…\(snippet(card.notes, around: w))…"
        }
        return nil
    }

    private func snippet(_ text: String, around w: String) -> String {
        guard let r = text.range(of: w, options: .caseInsensitive) else { return String(text.prefix(30)) }
        let start = text.index(r.lowerBound, offsetBy: -10, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 20, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
}
