import Foundation

public struct BrowterConfig: Codable, Equatable, Sendable {
    public var schema: String?
    public var fallback: String
    public var unwrapSafeLinks: Bool
    public var routes: [RouteConfig]

    public static let defaultFallback = "com.apple.Safari"
    public static let defaultSchemaURL = "https://raw.githubusercontent.com/marsidev/browter/main/config.schema.json"

    public init(
        schema: String? = nil,
        fallback: String = BrowterConfig.defaultFallback,
        unwrapSafeLinks: Bool = true,
        routes: [RouteConfig] = []
    ) {
        self.schema = schema
        self.fallback = fallback
        self.unwrapSafeLinks = unwrapSafeLinks
        self.routes = routes
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case fallback, unwrapSafeLinks, routes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decodeIfPresent(String.self, forKey: .schema)
        self.fallback = try container.decodeIfPresent(String.self, forKey: .fallback) ?? BrowterConfig.defaultFallback
        self.unwrapSafeLinks = try container.decodeIfPresent(Bool.self, forKey: .unwrapSafeLinks) ?? true
        self.routes = try container.decodeIfPresent([RouteConfig].self, forKey: .routes) ?? []
    }

    public static func load(from path: String) throws -> BrowterConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BrowterConfig.self, from: data)
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A) // trailing newline
        try data.write(to: url, options: .atomic)
    }

    /// Adds a domain or regex pattern to an existing route matching `(browser, profile)`,
    /// or creates a new route if none exists. Returns `false` if the rule was already present.
    @discardableResult
    public mutating func addRule(_ rule: String, browser: String, profile: String? = nil, isRegex: Bool = false) -> Bool {
        let normalizedProfile = profile?.isEmpty == true ? nil : profile
        if let idx = routes.firstIndex(where: { $0.browser == browser && $0.profile == normalizedProfile }) {
            if isRegex {
                if routes[idx].patterns.contains(rule) { return false }
                routes[idx].patterns.append(rule)
            } else {
                if routes[idx].domains.contains(rule) { return false }
                routes[idx].domains.append(rule)
            }
            return true
        }
        let newRoute = RouteConfig(
            browser: browser,
            profile: normalizedProfile,
            domains: isRegex ? [] : [rule],
            patterns: isRegex ? [rule] : []
        )
        routes.append(newRoute)
        return true
    }

    /// Removes all occurrences of `rule` from `domains` and `patterns` across routes.
    /// Drops routes that become empty. Returns the number of removed entries.
    @discardableResult
    public mutating func removeRule(_ rule: String) -> Int {
        var removed = 0
        for i in routes.indices {
            let beforeD = routes[i].domains.count
            routes[i].domains.removeAll { $0 == rule }
            removed += beforeD - routes[i].domains.count

            let beforeP = routes[i].patterns.count
            routes[i].patterns.removeAll { $0 == rule }
            removed += beforeP - routes[i].patterns.count
        }
        routes.removeAll { $0.domains.isEmpty && $0.patterns.isEmpty }
        return removed
    }
}

public struct RouteConfig: Codable, Equatable, Sendable {
    public var browser: String
    public var profile: String?
    public var domains: [String]
    public var patterns: [String]
    public var hints: [String]?
    public var useAppleScript: Bool

    public init(
        browser: String,
        profile: String? = nil,
        domains: [String] = [],
        patterns: [String] = [],
        hints: [String]? = nil,
        useAppleScript: Bool = true
    ) {
        self.browser = browser
        self.profile = profile
        self.domains = domains
        self.patterns = patterns
        self.hints = hints
        self.useAppleScript = useAppleScript
    }

    enum CodingKeys: String, CodingKey {
        case browser, profile, domains, patterns, hints, useAppleScript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.browser = try container.decode(String.self, forKey: .browser)
        self.profile = try container.decodeIfPresent(String.self, forKey: .profile)
        self.domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
        self.patterns = try container.decodeIfPresent([String].self, forKey: .patterns) ?? []
        self.hints = try container.decodeIfPresent([String].self, forKey: .hints)
        self.useAppleScript = try container.decodeIfPresent(Bool.self, forKey: .useAppleScript) ?? true
    }
}
