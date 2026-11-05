import AuthenticationServices
import Foundation

import UPasswordsCore

/// Registers non-secret credential identities for macOS AutoFill suggestions.
@MainActor
enum CredentialProviderIdentityStore {
    private static let store = ASCredentialIdentityStore.shared

    /// Replaces the system index with the current vault's eligible login items.
    /// Password values are never passed to AuthenticationServices.
    static func replace(with cards: [Card]) {
        let enabled = cards.filter { $0.autofillEnabled }
        let withLogin = enabled.filter { !$0.login.isEmpty }
        let withWebsite = withLogin.filter { card in
            card.fields.contains { $0.type == .website && !$0.value.isEmpty && $0.siteMatch != .never }
        }
        Log.info("autofill", "macOS identity candidates: cards=\(cards.count) enabled=\(enabled.count) login=\(withLogin.count) website=\(withWebsite.count)")
        var indexedKeys = Set<String>()
        let identities = cards.flatMap { card -> [ASPasswordCredentialIdentity] in
            guard card.autofillEnabled,
                  !card.login.isEmpty else { return [] }
            return card.fields.compactMap { field in
                guard field.type == .website,
                      !field.value.isEmpty,
                      field.siteMatch != .never,
                      let service = serviceIdentifier(for: field.value) else { return nil }
                let key = "\(card.id.uuidString)|\(service.identifier)"
                guard indexedKeys.insert(key).inserted else { return nil }
                return ASPasswordCredentialIdentity(
                    serviceIdentifier: service,
                    user: card.login,
                    recordIdentifier: card.id.uuidString)
            }
        }

        store.replaceCredentialIdentities(identities) { success, error in
            guard success else {
                Log.warn(
                    "autofill",
                    "macOS credential identity update failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            Log.info("autofill", "macOS credential identities updated: count=\(identities.count)")
        }
    }

    private static func serviceIdentifier(for website: String) -> ASCredentialServiceIdentifier? {
        let trimmed = website.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.user == nil,
              components.password == nil,
              components.host?.isEmpty == false else { return nil }
        return ASCredentialServiceIdentifier(identifier: components.string ?? value, type: .URL)
    }
}
