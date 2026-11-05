import Foundation

/// 按非空密码明文聚合卡片身份的重复密码分析。
/// 结果只允许留在已解锁会话内，不得持久化或输出到日志。
public enum SamePasswordsService {
    /// password → card ids using it.
    public static func groups(cards: [Card]) -> [String: [UUID]] {
        var out: [String: [UUID]] = [:]
        for c in cards where !c.trashed && !c.template {
            for f in c.fields where f.type == .password && !f.value.isEmpty {
                out[f.value, default: []].append(c.id)
            }
        }
        return out.filter { $0.value.count > 1 }
    }

    /// Card identities that occur in repeated-password groups.
    ///
    /// The result contains no password values and can be retained for UI lookup.
    public static func cardIDsWithReusedPasswords(cards: [Card]) -> Set<UUID> {
        var cardIDs = Set<UUID>()
        for ids in groups(cards: cards).values {
            cardIDs.formUnion(ids)
        }
        return cardIDs
    }
}
