import Foundation

/// Matches an HTTP(S) page URL against a website field's saved rule.
public enum SiteMatching {
    private static let compoundPublicSuffixes: Set<String> = [
        "ac.jp", "ac.nz", "ac.uk", "asn.au", "co.in", "co.jp", "co.kr", "co.nz", "co.uk",
        "com.ar", "com.au", "com.br", "com.cn", "com.hk", "com.mx", "com.my", "com.ph",
        "com.sg", "com.tr", "com.tw", "edu.au", "gov.au", "gov.uk", "net.au", "net.cn",
        "net.in", "net.nz", "net.uk", "org.au", "org.cn", "org.in", "org.nz", "org.uk",
        "appspot.com", "azurewebsites.net", "blogspot.com", "cloudfront.net", "firebaseapp.com",
        "github.io", "herokuapp.com", "netlify.app", "pages.dev", "vercel.app", "web.app",
        "wordpress.com", "workers.dev",
    ]

    /// Returns whether `pageURL` matches a website value and its rule.
    /// - Parameters:
    ///   - pageURL: Current page URL. Only HTTP and HTTPS pages are eligible.
    ///   - site: Saved website field.
    /// - Returns: Whether the page satisfies the field's matching rule.
    public static func matches(_ pageURL: String, site: Field) -> Bool {
        matches(pageURL, website: site.value, mode: site.siteMatch)
    }

    /// Returns whether any website field matches the page.
    /// - Parameters:
    ///   - pageURL: Current page URL. Only HTTP and HTTPS pages are eligible.
    ///   - sites: Candidate website fields; non-website fields are ignored.
    /// - Returns: Whether at least one website field's matching rule accepts the page.
    public static func matches(_ pageURL: String, sites: [Field]) -> Bool {
        sites.contains { $0.type == .website && matches(pageURL, site: $0) }
    }

    /// Returns whether a page URL matches a website value and rule.
    /// - Parameters:
    ///   - pageURL: Current page URL. Only HTTP and HTTPS pages are eligible.
    ///   - website: Saved URL or rule expression.
    ///   - mode: Rule applied to the saved value.
    /// - Returns: Whether the page satisfies the matching rule.
    public static func matches(_ pageURL: String, website: String, mode: SiteMatchMode) -> Bool {
        guard let page = URLComponents(string: pageURL),
              let scheme = page.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let pageHost = page.host?.lowercased(),
              !pageHost.isEmpty else { return false }

        switch mode {
        case .never:
            return false
        case .domain:
            guard let savedHost = components(for: website)?.host else { return false }
            return baseDomain(pageHost) == baseDomain(savedHost.lowercased())
        case .host:
            guard let saved = components(for: website), let savedHost = saved.host?.lowercased() else {
                return false
            }
            return pageHost == savedHost && (page.port ?? defaultPort(scheme)) ==
                (saved.port ?? defaultPort(saved.scheme?.lowercased() ?? "https"))
        case .startsWith:
            guard let saved = normalizedURL(website), let page = normalizedURL(pageURL) else { return false }
            return page.hasPrefix(saved)
        case .exactURL:
            guard let saved = normalizedURL(website), let page = normalizedURL(pageURL) else { return false }
            return page == saved
        case .regex:
            guard website.count <= 256, pageURL.count <= 2048,
                  isSafeRegularExpression(website),
                  let expression = try? NSRegularExpression(pattern: website) else { return false }
            let range = NSRange(pageURL.startIndex..<pageURL.endIndex, in: pageURL)
            return expression.firstMatch(in: pageURL, range: range) != nil
        case .wildcard:
            guard website.count <= 2048 else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: website)
                .replacingOccurrences(of: "\\*", with: ".*")
            guard let expression = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(pageURL.startIndex..<pageURL.endIndex, in: pageURL)
            return expression.firstMatch(in: pageURL, range: range) != nil
        }
    }

    private static func components(for raw: String) -> URLComponents? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              components.host?.isEmpty == false else { return nil }
        return components
    }

    private static func normalizedURL(_ raw: String) -> String? {
        guard var components = components(for: raw) else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string
    }

    private static func defaultPort(_ scheme: String) -> Int {
        scheme == "http" ? 80 : 443
    }

    private static func baseDomain(_ rawHost: String) -> String {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if host == "localhost" || host.contains(":") || isIPv4(host) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return "" }
        let suffix = labels.suffix(2).joined(separator: ".")
        let suffixLength = compoundPublicSuffixes.contains(suffix) ? 2 : 1
        guard labels.count > suffixLength else { return "" }
        return labels.suffix(suffixLength + 1).joined(separator: ".")
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private static func isSafeRegularExpression(_ pattern: String) -> Bool {
        guard pattern.count <= 256,
              !pattern.contains("(?<=") && !pattern.contains("(?<!") else { return false }
        let characters = Array(pattern)
        var groups: [(quantified: Bool, alternation: Bool)] = []
        var unboundedRepeats = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                if index + 1 < characters.count,
                   let digit = characters[index + 1].wholeNumberValue, (1...9).contains(digit) {
                    return false
                }
                index += 2
                continue
            }
            if character == "[" {
                index += 1
                while index < characters.count, characters[index] != "]" {
                    if characters[index] == "\\" { index += 1 }
                    index += 1
                }
                guard index < characters.count else { return false }
                index += 1
                continue
            }
            if character == "(" {
                groups.append((false, false))
            } else if character == "|" {
                if !groups.isEmpty { groups[groups.count - 1].alternation = true }
            } else if character == ")" {
                guard let group = groups.popLast() else { return false }
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if let next, "*+?{".contains(next), group.quantified || group.alternation {
                    return false
                }
                if next.map({ "*+?{".contains($0) }) == true, !groups.isEmpty {
                    groups[groups.count - 1].quantified = true
                }
            } else {
                let remainder = character == "{" ? String(characters[index...]) : ""
                let isCountedQuantifier = character == "{"
                    && remainder.range(of: #"^\{\d+(?:,\d*)?\}"#, options: .regularExpression) != nil
                guard !(character == "?" && index > 0 && characters[index - 1] == "("),
                      "*+?".contains(character) || isCountedQuantifier else {
                    index += 1
                    continue
                }
                let isUnboundedCount = character == "{"
                    && remainder.range(of: #"^\{\d+,\}"#, options: .regularExpression) != nil
                if character == "*" || character == "+" || isUnboundedCount {
                    unboundedRepeats += 1
                    if unboundedRepeats > 1 { return false }
                }
                if !groups.isEmpty { groups[groups.count - 1].quantified = true }
            }
            index += 1
        }
        return groups.isEmpty
    }
}
