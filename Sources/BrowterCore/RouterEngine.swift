import Foundation

public struct CompiledRoute: @unchecked Sendable {
    public let index: Int
    public let browser: String
    public let profile: String?
    public let hints: [String]
    public let useAppleScript: Bool
    public let regexes: [NSRegularExpression]

    public func matches(_ url: String) -> Bool {
        let range = NSRange(url.startIndex..., in: url)
        return regexes.contains { $0.firstMatch(in: url, range: range) != nil }
    }
}

public enum RouteDecision: Sendable {
    case route(CompiledRoute, matchURL: String)
    case fallback(browser: String, matchURL: String)

    public var browser: String {
        switch self {
        case .route(let r, _): return r.browser
        case .fallback(let b, _): return b
        }
    }

    public var profile: String? {
        switch self {
        case .route(let r, _): return r.profile
        case .fallback: return nil
        }
    }

    public var matchURL: String {
        switch self {
        case .route(_, let url), .fallback(_, let url): return url
        }
    }
}

public struct CompiledRouter: Sendable {
    public let config: BrowterConfig
    public let routes: [CompiledRoute]
    public let warnings: [String]

    public init(config: BrowterConfig) {
        self.config = config
        var compiled: [CompiledRoute] = []
        var warnings: [String] = []

        for (index, entry) in config.routes.enumerated() {
            var regexes: [NSRegularExpression] = []

            for domain in entry.domains {
                let pattern = RouterEngine.domainToRegexPattern(domain)
                do {
                    regexes.append(try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
                } catch {
                    warnings.append("Route \(index): invalid domain rule '\(domain)': \(error.localizedDescription)")
                }
            }

            for pattern in entry.patterns {
                do {
                    regexes.append(try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
                } catch {
                    warnings.append("Route \(index): invalid regex '\(pattern)': \(error.localizedDescription)")
                }
            }

            let hints = entry.hints ?? RouterEngine.deriveHints(from: entry.domains)
            compiled.append(CompiledRoute(
                index: index,
                browser: entry.browser,
                profile: entry.profile,
                hints: hints,
                useAppleScript: entry.useAppleScript,
                regexes: regexes
            ))
        }

        self.routes = compiled
        self.warnings = warnings
    }

    public func decide(rawURL: String) -> RouteDecision {
        let target = config.unwrapSafeLinks ? (RouterEngine.safeLinkTarget(rawURL) ?? rawURL) : rawURL
        for route in routes where route.matches(target) {
            return .route(route, matchURL: target)
        }
        return .fallback(browser: config.fallback, matchURL: target)
    }
}

public enum RouterEngine {
    private static let safeLinkHosts = [
        "onecdn.static.microsoft",
        "safelinks.protection.outlook.com",
    ]

    /// Converts a human-friendly domain rule into a case-insensitive regex pattern:
    /// - `"example.com"` matches `example.com` (http/https, optional port, any path)
    /// - `"*.example.com"` matches `example.com` and any subdomain `a.b.example.com`
    /// - `".microsoft"` matches any host ending in `.microsoft` (e.g. `cloud.microsoft`)
    /// - `"github.com/myorg"` matches `github.com/myorg` and `github.com/myorg/...`
    public static func domainToRegexPattern(_ rawRule: String) -> String {
        var rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.lowercased().hasPrefix("https://") {
            rule = String(rule.dropFirst("https://".count))
        } else if rule.lowercased().hasPrefix("http://") {
            rule = String(rule.dropFirst("http://".count))
        }

        let hostPart: String
        let pathPart: String?
        if let slash = rule.firstIndex(of: "/") {
            hostPart = String(rule[..<slash])
            let tail = String(rule[rule.index(after: slash)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            pathPart = tail.isEmpty ? nil : tail
        } else {
            hostPart = rule
            pathPart = nil
        }

        let hostRegex: String
        if hostPart.hasPrefix("*.") {
            let base = String(hostPart.dropFirst(2))
            hostRegex = #"([a-z0-9-]+\.)*"# + NSRegularExpression.escapedPattern(for: base)
        } else if hostPart.hasPrefix(".") {
            let base = String(hostPart.dropFirst(1))
            hostRegex = #"([a-z0-9-]+\.)+"# + NSRegularExpression.escapedPattern(for: base)
        } else {
            hostRegex = NSRegularExpression.escapedPattern(for: hostPart)
        }

        let pathRegex: String
        if let pathPart {
            pathRegex = "/" + NSRegularExpression.escapedPattern(for: pathPart) + #"(/|$|\?|#)"#
        } else {
            pathRegex = #"(/|$|\?|#)"#
        }

        return #"^https?://"# + hostRegex + #"(:[0-9]+)?"# + pathRegex
    }

    /// Derives tab-URL substrings for AppleScript window matching from domain rules.
    public static func deriveHints(from domains: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in domains {
            var hint = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if hint.lowercased().hasPrefix("https://") {
                hint = String(hint.dropFirst("https://".count))
            } else if hint.lowercased().hasPrefix("http://") {
                hint = String(hint.dropFirst("http://".count))
            }
            if hint.hasPrefix("*.") {
                hint = String(hint.dropFirst(2))
            } else if hint.hasPrefix(".") {
                hint = String(hint.dropFirst(1))
            }
            hint = hint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !hint.isEmpty, seen.insert(hint).inserted else { continue }
            result.append(hint)
        }
        return result
    }

    /// Teams and Outlook wrap links in a safe-links page: `.../atp-safelinks.html?url=<destination>`.
    /// The wrapper stays the opened URL so the security page still runs; the destination is only
    /// used to choose the browser.
    public static func safeLinkTarget(_ raw: String) -> String? {
        guard let comps = URLComponents(string: raw),
              let host = comps.host?.lowercased(),
              safeLinkHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              let value = comps.queryItems?.first(where: { $0.name == "url" || $0.name == "u" })?.value else {
            return nil
        }
        var target = value
        if !hasHTTPPrefix(target), let once = target.removingPercentEncoding {
            target = once
        }
        guard hasHTTPPrefix(target) else { return nil }
        return target
    }

    /// Extracts the HTTP(S) URL from a macOS `.webloc` plist file.
    public static func parseWeblocURL(data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let url = plist["URL"] as? String,
              hasHTTPPrefix(url) else {
            return nil
        }
        return url
    }

    private static func hasHTTPPrefix(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}
