import Foundation

public struct BrowterConfig: Codable, Equatable, Sendable {
    public var fallback: String
    public var unwrapSafeLinks: Bool
    public var routes: [RouteConfig]

    public static let defaultFallback = "com.apple.Safari"

    public init(
        fallback: String = BrowterConfig.defaultFallback,
        unwrapSafeLinks: Bool = true,
        routes: [RouteConfig] = []
    ) {
        self.fallback = fallback
        self.unwrapSafeLinks = unwrapSafeLinks
        self.routes = routes
    }

    enum CodingKeys: String, CodingKey {
        case fallback, unwrapSafeLinks, routes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fallback = try container.decodeIfPresent(String.self, forKey: .fallback) ?? BrowterConfig.defaultFallback
        self.unwrapSafeLinks = try container.decodeIfPresent(Bool.self, forKey: .unwrapSafeLinks) ?? true
        self.routes = try container.decodeIfPresent([RouteConfig].self, forKey: .routes) ?? []
    }

    public static func load(from path: String) throws -> BrowterConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BrowterConfig.self, from: data)
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
