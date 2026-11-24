import BrowterCore
import Foundation
import Testing

@Suite("BrowterCore")
struct BrowterCoreTests {
    @Test("Domain rule: exact host")
    func exactHost() {
        let config = BrowterConfig(
            fallback: "com.brave.Browser",
            routes: [
                RouteConfig(browser: "com.google.Chrome", profile: "Profile 1", domains: ["example.com"]),
            ]
        )
        let router = CompiledRouter(config: config)

        #expect(router.decide(rawURL: "https://example.com").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "http://example.com:8080/path?a=1#frag").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://sub.example.com").browser == "com.brave.Browser")
        #expect(router.decide(rawURL: "https://notexample.com").browser == "com.brave.Browser")
    }

    @Test("Domain rule: wildcard subdomain (*.domain)")
    func wildcardSubdomain() {
        let config = BrowterConfig(
            fallback: "com.apple.Safari",
            routes: [
                RouteConfig(browser: "com.google.Chrome", domains: ["*.azure.com"]),
            ]
        )
        let router = CompiledRouter(config: config)

        #expect(router.decide(rawURL: "https://azure.com").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://portal.azure.com/foo").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://a.b.azure.com").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://myazure.com").browser == "com.apple.Safari")
    }

    @Test("Domain rule: TLD prefix (.microsoft)")
    func tldPrefix() {
        let config = BrowterConfig(
            fallback: "com.apple.Safari",
            routes: [
                RouteConfig(browser: "com.google.Chrome", domains: [".microsoft"]),
            ]
        )
        let router = CompiledRouter(config: config)

        #expect(router.decide(rawURL: "https://cloud.microsoft/home").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://teams.cloud.microsoft").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://microsoft/home").browser == "com.apple.Safari")
    }

    @Test("Domain rule: host + path prefix")
    func hostWithPathPrefix() {
        let config = BrowterConfig(
            fallback: "com.brave.Browser",
            routes: [
                RouteConfig(browser: "com.google.Chrome", domains: ["github.com/acme"]),
            ]
        )
        let router = CompiledRouter(config: config)

        #expect(router.decide(rawURL: "https://github.com/acme").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://github.com/acme/repo/pull/1").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://github.com/acme?tab=repositories").browser == "com.google.Chrome")
        #expect(router.decide(rawURL: "https://github.com/acme-other/repo").browser == "com.brave.Browser")
        #expect(router.decide(rawURL: "https://github.com/other/repo").browser == "com.brave.Browser")
    }

    @Test("SafeLinks unwrapping routes by destination while rejecting lookalike hosts")
    func safeLinksUnwrapping() {
        let wrapped = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fgithub.com%2Facme%2Fapp&data=123"
        #expect(RouterEngine.safeLinkTarget(wrapped) == "https://github.com/acme/app")

        let doubleEncoded = "https://statics.teams.cdn.office.net/atp"
        #expect(RouterEngine.safeLinkTarget(doubleEncoded) == nil)

        let teamsSafeLink = "https://res.cdn.office.net.onecdn.static.microsoft/atp-safelinks.html?u=https%253A%252F%252Fportal.azure.com%252F"
        #expect(RouterEngine.safeLinkTarget(teamsSafeLink) == "https://portal.azure.com/")

        let lookalike = "https://evil-safelinks.protection.outlook.com/?url=https%3A%2F%2Fgithub.com%2Facme"
        #expect(RouterEngine.safeLinkTarget(lookalike) == nil)

        let nonHTTP = "https://eur01.safelinks.protection.outlook.com/?url=javascript%3Aalert(1)"
        #expect(RouterEngine.safeLinkTarget(nonHTTP) == nil)
    }

    @Test("SafeLinks toggle can be disabled")
    func safeLinksDisabled() {
        let config = BrowterConfig(
            fallback: "com.brave.Browser",
            unwrapSafeLinks: false,
            routes: [
                RouteConfig(browser: "com.google.Chrome", domains: ["github.com/acme"]),
            ]
        )
        let router = CompiledRouter(config: config)
        let wrapped = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fgithub.com%2Facme"
        #expect(router.decide(rawURL: wrapped).browser == "com.brave.Browser")
    }

    @Test("Invalid regex produces warning without crashing")
    func invalidRegexIsNonFatal() {
        let config = BrowterConfig(
            fallback: "com.apple.Safari",
            routes: [
                RouteConfig(
                    browser: "com.google.Chrome",
                    domains: ["example.com"],
                    patterns: ["[unterminated"]
                ),
            ]
        )
        let router = CompiledRouter(config: config)

        #expect(router.warnings.count == 1)
        #expect(router.decide(rawURL: "https://example.com").browser == "com.google.Chrome")
    }

    @Test("Hints are auto-derived from domains when omitted")
    func hintDerivation() {
        let hints = RouterEngine.deriveHints(from: [
            "github.com/acme",
            "*.azure.com",
            ".microsoft",
            "https://portal.azure.com/",
            "*.azure.com",
        ])
        #expect(hints == ["github.com/acme", "azure.com", "microsoft", "portal.azure.com"])
    }

    @Test("Webloc plist parsing")
    func weblocParsing() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>URL</key>
            <string>https://github.com/acme/repo</string>
        </dict>
        </plist>
        """
        #expect(RouterEngine.parseWeblocURL(data: Data(xml.utf8)) == "https://github.com/acme/repo")
        #expect(RouterEngine.parseWeblocURL(data: Data("not a plist".utf8)) == nil)
    }

    @Test("Config JSON decoding applies sensible defaults")
    func configDefaults() throws {
        let json = """
        {
          "routes": [
            {
              "browser": "com.google.Chrome",
              "profile": "Profile 1",
              "domains": ["github.com/acme"]
            }
          ]
        }
        """
        let config = try JSONDecoder().decode(BrowterConfig.self, from: Data(json.utf8))
        #expect(config.fallback == BrowterConfig.defaultFallback)
        #expect(config.unwrapSafeLinks == true)
        #expect(config.routes.count == 1)
        #expect(config.routes[0].patterns.isEmpty)
        #expect(config.routes[0].useAppleScript == true)
        #expect(config.routes[0].hints == nil)
    }

    @Test("First matching route wins")
    func firstMatchWins() {
        let config = BrowterConfig(
            fallback: "com.apple.Safari",
            routes: [
                RouteConfig(browser: "com.google.Chrome", profile: "Profile 1", domains: ["github.com/acme"]),
                RouteConfig(browser: "org.mozilla.firefox", domains: ["github.com"]),
            ]
        )
        let router = CompiledRouter(config: config)
        let work = router.decide(rawURL: "https://github.com/acme/browter")
        let other = router.decide(rawURL: "https://github.com/someone/repo")

        #expect(work.browser == "com.google.Chrome")
        #expect(work.profile == "Profile 1")
        #expect(other.browser == "org.mozilla.firefox")
    }
}
