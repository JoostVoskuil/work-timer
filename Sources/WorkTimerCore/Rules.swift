import Foundation

public enum DomainMatcher {
    /// Lowercases, strips trailing dots and credentials/ports, and converts IDNs to punycode.
    public static func normalize(_ raw: String) -> String? {
        var h = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !h.isEmpty, !h.contains("/"), !h.contains("@"), !h.contains(" ") else { return nil }
        while h.hasSuffix(".") { h.removeLast() }
        if let colon = h.lastIndex(of: ":"), !h.contains("]") { h = String(h[..<colon]) }
        guard !h.isEmpty, let url = URL(string: "https://\(h)"), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// Exact match, or hostname ends with "." + pattern. `notnu.nl` and `nu.nl.example.com` do not match `nu.nl`.
    public static func matches(host: String, pattern: String) -> Bool {
        guard let h = normalize(host), let p = normalize(pattern) else { return false }
        return h == p || h.hasSuffix("." + p)
    }
}

public struct RuleDecision: Equatable {
    public var category: Category
    public var isWork: Bool { category == .work }
    public var reason: Reason
    public var explanation: String
}

public struct RuleSet {
    public var rules: [ClassificationRule]
    public init(_ rules: [ClassificationRule]) { self.rules = rules }

    public static let defaults: [ClassificationRule] = [
        ClassificationRule(kind: .domain, pattern: "nu.nl", isWork: false, note: "Default private"),
        ClassificationRule(kind: .domain, pattern: "nos.nl", isWork: false, note: "Default private"),
        ClassificationRule(kind: .domain, pattern: "tweakers.net", isWork: false, note: "Default private"),
        ClassificationRule(kind: .app, pattern: "org.videolan.vlc", isWork: false, note: "VLC, default private"),
    ]

    /// A domain-specific rule wins over an app-wide rule; among equals, private wins, then learn.
    public func decide(app: String?, domain: String?) -> RuleDecision? {
        if let domain {
            let hits = rules.filter { $0.kind == .domain && DomainMatcher.matches(host: domain, pattern: $0.pattern) }
            if let d = pick(hits, label: "domain") { return d }
        }
        if let app {
            let hits = rules.filter { $0.kind == .app && $0.pattern.caseInsensitiveCompare(app) == .orderedSame }
            if let d = pick(hits, label: "app") { return d }
        }
        return nil
    }

    private func pick(_ hits: [ClassificationRule], label: String) -> RuleDecision? {
        guard !hits.isEmpty else { return nil }
        if let p = hits.first(where: { $0.category == .privateTime }) {
            return RuleDecision(category: .privateTime, reason: .privateRule, explanation: "Private \(label) rule: \(p.pattern)")
        }
        if let l = hits.first(where: { $0.category == .learn }) {
            return RuleDecision(category: .learn, reason: .learnRule, explanation: "Learn \(label) rule: \(l.pattern)")
        }
        return RuleDecision(category: .work, reason: .workRule, explanation: "Work \(label) rule: \(hits[0].pattern)")
    }
}
