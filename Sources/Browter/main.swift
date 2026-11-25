import AppKit
#if canImport(BrowterCore)
import BrowterCore
#endif
import Foundation

// MARK: - Config Path Resolution

func resolveConfigPath() -> String {
    if let env = ProcessInfo.processInfo.environment["BROWTER_CONFIG"], !env.isEmpty {
        return (env as NSString).expandingTildeInPath
    }
    if let pref = UserDefaults.standard.string(forKey: "configPath"), !pref.isEmpty {
        return (pref as NSString).expandingTildeInPath
    }
    return NSHomeDirectory() + "/.config/browter/config.json"
}

// MARK: - Browser Resolution

struct ResolvedApp: Sendable {
    let url: URL
    let bundleID: String?
    let executableURL: URL?
}

enum BrowserFamily {
    case chromium
    case firefox
    case other

    static func detect(bundleID: String?) -> BrowserFamily {
        guard let id = bundleID?.lowercased() else { return .other }
        let chromiumIDs: Set<String> = [
            "com.google.chrome",
            "com.google.chrome.beta",
            "com.google.chrome.canary",
            "com.google.chrome.dev",
            "com.brave.browser",
            "com.brave.browser.beta",
            "com.brave.browser.nightly",
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.beta",
            "com.vivaldi.vivaldi",
            "org.chromium.chromium",
            "com.operasoftware.opera",
            "company.thebrowser.browser",
        ]
        if chromiumIDs.contains(id) { return .chromium }
        if id.hasPrefix("org.mozilla.firefox") || id == "app.zen-browser.zen" || id == "org.mozilla.librewolf" {
            return .firefox
        }
        return .other
    }
}

func resolveApplication(for spec: String) -> ResolvedApp? {
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let ownBundleID = Bundle.main.bundleIdentifier

    func wrap(_ url: URL) -> ResolvedApp? {
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
        // Never route back to Browter itself (avoids infinite recursion).
        if let ownBundleID, bundleID == ownBundleID {
            NSLog("Browter: refusing to route to self (\(ownBundleID))")
            return nil
        }
        return ResolvedApp(url: url, bundleID: bundleID, executableURL: bundle?.executableURL)
    }

    // 1. Explicit filesystem path
    if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
        let expanded = (trimmed as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return wrap(URL(fileURLWithPath: expanded))
        }
    }

    // 2. Bundle identifier
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
        return wrap(appURL)
    }

    // 3. Application name in standard macOS application directories
    let appName = trimmed.hasSuffix(".app") ? trimmed : "\(trimmed).app"
    let searchDirs = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
    ]
    for dir in searchDirs {
        let candidate = "\(dir)/\(appName)"
        if FileManager.default.fileExists(atPath: candidate) {
            return wrap(URL(fileURLWithPath: candidate))
        }
    }

    return nil
}

// MARK: - Profile Discovery

struct DiscoveredProfile {
    let directory: String
    let displayName: String
}

func discoverBrowserProfiles() -> [(browser: String, bundleID: String, profiles: [DiscoveredProfile])] {
    let appSupport = NSHomeDirectory() + "/Library/Application Support"
    var results: [(String, String, [DiscoveredProfile])] = []

    let chromiumBrowsers: [(name: String, bundleID: String, relPath: String)] = [
        ("Google Chrome", "com.google.Chrome", "Google/Chrome/Local State"),
        ("Google Chrome Beta", "com.google.Chrome.beta", "Google/Chrome Beta/Local State"),
        ("Google Chrome Canary", "com.google.Chrome.canary", "Google/Chrome Canary/Local State"),
        ("Brave Browser", "com.brave.Browser", "BraveSoftware/Brave-Browser/Local State"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge/Local State"),
        ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi/Local State"),
        ("Chromium", "org.chromium.Chromium", "Chromium/Local State"),
    ]

    for browser in chromiumBrowsers {
        let path = "\(appSupport)/\(browser.relPath)"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileDict = json["profile"] as? [String: Any],
              let infoCache = profileDict["info_cache"] as? [String: [String: Any]] else {
            continue
        }
        let profiles = infoCache.keys.sorted().map { dir -> DiscoveredProfile in
            let meta = infoCache[dir] ?? [:]
            let name = (meta["name"] as? String) ?? dir
            return DiscoveredProfile(directory: dir, displayName: name)
        }
        if !profiles.isEmpty {
            results.append((browser.name, browser.bundleID, profiles))
        }
    }

    let firefoxBrowsers: [(name: String, bundleID: String, relPath: String)] = [
        ("Firefox", "org.mozilla.firefox", "Firefox/profiles.ini"),
        ("Zen Browser", "app.zen-browser.zen", "zen/profiles.ini"),
    ]

    for browser in firefoxBrowsers {
        let path = "\(appSupport)/\(browser.relPath)"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        var profiles: [DiscoveredProfile] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Name=") {
                let name = String(trimmed.dropFirst("Name=".count))
                if !name.isEmpty {
                    profiles.append(DiscoveredProfile(directory: name, displayName: name))
                }
            }
        }
        if !profiles.isEmpty {
            results.append((browser.name, browser.bundleID, profiles))
        }
    }

    return results
}

// MARK: - Route Coordinator

final class RouteCoordinator: @unchecked Sendable {
    static let chromeBundleID = "com.google.Chrome"

    private let configPath: String
    private let debug: Bool
    private let routeQueue = DispatchQueue(label: "dev.marsidev.browter.route", qos: .userInitiated)
    private let logQueue = DispatchQueue(label: "dev.marsidev.browter.log", qos: .utility)
    private let isoFormatter = ISO8601DateFormatter()

    private var compiledRouter: CompiledRouter
    private var configModDate: Date?
    private var windowIDs: [String: String] = [:]

    init(configPath: String) {
        self.configPath = configPath
        self.debug = ProcessInfo.processInfo.environment["BROWTER_DEBUG"] != nil
            || UserDefaults.standard.bool(forKey: "debug")
        self.compiledRouter = CompiledRouter(config: BrowterConfig())
        reloadConfigIfNeeded(force: true)
    }

    func clearCachedWindows(forBundleID bundleID: String) {
        guard bundleID == Self.chromeBundleID else { return }
        routeQueue.async {
            self.windowIDs.removeAll()
        }
    }

    func handleURL(_ url: URL, raw: String) {
        routeQueue.async {
            self.routeOnQueue(url, raw: raw)
        }
    }

    func handleFileURLs(_ urls: [URL]) {
        routeQueue.async {
            for url in urls {
                if url.isFileURL, url.pathExtension.lowercased() == "webloc",
                   let data = try? Data(contentsOf: url),
                   let innerString = RouterEngine.parseWeblocURL(data: data),
                   let innerURL = URL(string: innerString) {
                    self.routeOnQueue(innerURL, raw: innerString)
                } else {
                    self.routeOnQueue(url, raw: url.absoluteString)
                }
            }
        }
    }

    private func reloadConfigIfNeeded(force: Bool = false) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: configPath)
        let modDate = attrs?[.modificationDate] as? Date

        if !force && modDate == configModDate {
            return
        }

        guard FileManager.default.fileExists(atPath: configPath) else {
            configModDate = nil
            compiledRouter = CompiledRouter(config: BrowterConfig())
            if force {
                NSLog("Browter: no config at \(configPath); using fallback \(BrowterConfig.defaultFallback)")
            }
            return
        }

        do {
            let loaded = try BrowterConfig.load(from: configPath)
            let router = CompiledRouter(config: loaded)
            for warning in router.warnings {
                NSLog("Browter: \(warning)")
            }
            self.compiledRouter = router
            self.configModDate = modDate
            self.windowIDs.removeAll()
            if debug {
                appendLog("\(isoFormatter.string(from: Date())) reloaded config (\(router.routes.count) routes) from \(configPath)\n")
            }
        } catch {
            NSLog("Browter: failed to load \(configPath): \(error.localizedDescription) (keeping previous config)")
        }
    }

    private func routeOnQueue(_ url: URL, raw: String) {
        let start = DispatchTime.now().uptimeNanoseconds
        reloadConfigIfNeeded()

        let decision = compiledRouter.decide(rawURL: raw)
        switch decision {
        case .route(let route, let matchURL):
            guard let app = resolveApplication(for: route.browser) else {
                NSLog("Browter: browser '\(route.browser)' not found; falling back")
                openFallback(url, matchURL: matchURL, start: start)
                return
            }

            if let profile = route.profile, !profile.isEmpty {
                let family = BrowserFamily.detect(bundleID: app.bundleID)
                if app.bundleID == Self.chromeBundleID,
                   route.useAppleScript,
                   !route.hints.isEmpty,
                   !NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleID).isEmpty,
                   openViaAppleScript(raw, profile: profile, hints: route.hints) {
                    log(start, "applescript[\(profile)]", matchURL)
                    return
                }
                let how = openWithProfile(raw, app: app, family: family, profile: profile)
                log(start, "\(route.browser)[\(profile)] \(how)", matchURL)
                return
            }

            openWithWorkspace(url, app: app)
            log(start, route.browser, matchURL)

        case .fallback(_, let matchURL):
            openFallback(url, matchURL: matchURL, start: start)
        }
    }

    private func openFallback(_ url: URL, matchURL: String, start: UInt64) {
        let app = resolveApplication(for: compiledRouter.config.fallback)
            ?? resolveApplication(for: BrowterConfig.defaultFallback)
        guard let app else {
            NSLog("Browter: neither fallback '\(compiledRouter.config.fallback)' nor Safari could be resolved")
            return
        }
        openWithWorkspace(url, app: app)
        log(start, "fallback(\(app.bundleID ?? app.url.lastPathComponent))", matchURL)
    }

    private func openWithWorkspace(_ url: URL, app: ResolvedApp) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: config) { _, error in
            if let error {
                NSLog("Browter: open failed for \(app.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Adds the URL as a tab in Google Chrome's existing profile window via chromium-tab.applescript.
    /// Returns false when Chrome has no matching window or Automation permission is not granted.
    private func openViaAppleScript(_ url: String, profile: String, hints: [String]) -> Bool {
        guard let script = Bundle.main.path(forResource: "chromium-tab", ofType: "applescript") else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [script, url, windowIDs[profile] ?? ""] + hints
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            done.signal()
        }
        do {
            try process.run()
        } catch {
            return false
        }

        // The first call can show the Automation permission dialog; 10s allows answering it,
        // and the caller falls back to spawning Chrome if it times out.
        if done.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            return false
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, text.hasPrefix("ok ") {
            let parts = text.split(separator: " ")
            if parts.count >= 2 {
                windowIDs[profile] = String(parts[1])
            }
            return true
        }
        if debug {
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("Browter: AppleScript fallback status=\(process.terminationStatus) out=\(text) err=\(errText)")
        }
        return false
    }

    private func openWithProfile(_ url: String, app: ResolvedApp, family: BrowserFamily, profile: String) -> String {
        let args: [String]
        switch family {
        case .firefox:
            args = ["-P", profile, url]
        case .chromium, .other:
            args = ["--profile-directory=\(profile)", url]
        }

        let isRunning: Bool
        if let bundleID = app.bundleID {
            isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        } else {
            isRunning = false
        }

        if !isRunning {
            // Cold start through Launch Services keeps camera/microphone permissions attributed to the browser.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.arguments = args
            NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
                if let error {
                    NSLog("Browter: launch failed for \(app.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return "launch"
        }

        guard let executableURL = app.executableURL else {
            if let parsed = URL(string: url) { openWithWorkspace(parsed, app: app) }
            return "workspace-fallback"
        }

        // Browser is already running: spawning its binary hands the URL to the running instance and exits.
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let spawned = DispatchTime.now().uptimeNanoseconds
        process.terminationHandler = { [self, url, profile, spawned] _ in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - spawned) / 1_000_000
            self.logHelper(ms, profile, url)
        }
        do {
            try process.run()
        } catch {
            NSLog("Browter: spawn failed for \(executableURL.lastPathComponent): \(error.localizedDescription)")
            return "spawn-failed"
        }
        return "spawn"
    }

    private func appendLog(_ line: String) {
        guard debug else { return }
        let logsDir = NSHomeDirectory() + "/Library/Logs"
        let path = logsDir + "/Browter.log"
        logQueue.async {
            try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
            let data = Data(line.utf8)
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }

    private func log(_ start: UInt64, _ target: String, _ url: String) {
        guard debug else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let ts = isoFormatter.string(from: Date())
        appendLog("\(ts) \(String(format: "%.2f", ms)) ms -> \(target) \(url)\n")
    }

    private func logHelper(_ ms: Double, _ profile: String, _ url: String) {
        guard debug else { return }
        let ts = isoFormatter.string(from: Date())
        appendLog("\(ts) helper[\(profile)] exited after \(String(format: "%.0f", ms)) ms -> \(url)\n")
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: RouteCoordinator

    init(coordinator: RouteCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered here (not in didFinishLaunching) so the URL that launched us is not lost.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [coordinator] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bundleID = app.bundleIdentifier {
                coordinator.clearCachedWindows(forBundleID: bundleID)
            }
        }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        guard let url = URL(string: string) else {
            NSLog("Browter: ignoring invalid URL '\(string)'")
            return
        }
        coordinator.handleURL(url, raw: string)
    }

    /// Local .html / .webloc files when Browter is also configured as their handler.
    func application(_ application: NSApplication, open urls: [URL]) {
        coordinator.handleFileURLs(urls)
    }
}

// MARK: - CLI Utilities

func printHelp(configPath: String) {
    print("""
    Usage: browter <command> [options]

    Commands:
      init [--force]                                    Create starter config file
      list                                              Show current fallback and routes
      add <rule> --browser <app> [--profile <p>] [--regex]
                                                        Add a domain or regex rule
      remove <rule>                                     Remove a domain or regex rule
      profiles                                          List installed browser profiles
      check                                             Validate config and resolved browsers
      test <url>                                        Show which browser would open <url>
      edit                                              Open config in $EDITOR (or default app)
      version                                           Print version
      help                                              Show this help

    Config file: \(configPath) (override with BROWTER_CONFIG)
    """)
}

func runCLI(args: [String], configPath: String) -> Int32? {
    guard let first = args.first else { return nil }
    let rest = Array(args.dropFirst())

    switch first {
    case "help", "--help", "-h":
        printHelp(configPath: configPath)
        return 0

    case "version", "--version", "-v":
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        print("Browter \(version)")
        return 0

    case "init":
        let force = rest.contains("--force")
        if FileManager.default.fileExists(atPath: configPath) && !force {
            fputs("Config already exists at \(configPath) (pass --force to overwrite)\n", stderr)
            return 1
        }
        let starter = BrowterConfig(
            schema: BrowterConfig.defaultSchemaURL,
            fallback: BrowterConfig.defaultFallback,
            unwrapSafeLinks: true,
            routes: []
        )
        do {
            try starter.save(to: configPath)
            print("Created \(configPath)")
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "list":
        guard FileManager.default.fileExists(atPath: configPath) else {
            fputs("error: config not found at \(configPath) (run 'browter init')\n", stderr)
            return 1
        }
        do {
            let config = try BrowterConfig.load(from: configPath)
            print("Config: \(configPath)")
            print("Fallback: \(config.fallback)")
            print("Unwrap SafeLinks: \(config.unwrapSafeLinks)")
            if config.routes.isEmpty {
                print("Routes: (none)")
            } else {
                print("Routes:")
                for (i, r) in config.routes.enumerated() {
                    let prof = r.profile.map { " [\($0)]" } ?? ""
                    print("  [\(i)] \(r.browser)\(prof)")
                    for d in r.domains { print("      domain:  \(d)") }
                    for p in r.patterns { print("      pattern: \(p)") }
                }
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "add":
        guard let rule = rest.first, !rule.hasPrefix("-") else {
            fputs("usage: browter add <domain-or-pattern> --browser <app> [--profile <name>] [--regex]\n", stderr)
            return 2
        }
        var browser: String?
        var profile: String?
        var isRegex = false
        var i = 1
        while i < rest.count {
            switch rest[i] {
            case "--browser", "-b":
                if i + 1 < rest.count { browser = rest[i + 1]; i += 2 } else { i += 1 }
            case "--profile", "-p":
                if i + 1 < rest.count { profile = rest[i + 1]; i += 2 } else { i += 1 }
            case "--regex", "-r":
                isRegex = true; i += 1
            default:
                fputs("unknown option: \(rest[i])\n", stderr)
                return 2
            }
        }
        guard let browser, !browser.isEmpty else {
            fputs("error: --browser is required\n", stderr)
            return 2
        }
        if isRegex {
            do {
                _ = try NSRegularExpression(pattern: rule, options: [.caseInsensitive])
            } catch {
                fputs("error: invalid regex '\(rule)': \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        var config: BrowterConfig
        if FileManager.default.fileExists(atPath: configPath) {
            do {
                config = try BrowterConfig.load(from: configPath)
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                return 1
            }
        } else {
            config = BrowterConfig(schema: BrowterConfig.defaultSchemaURL)
        }
        let added = config.addRule(rule, browser: browser, profile: profile, isRegex: isRegex)
        if !added {
            print("Already configured: \(rule)")
            return 0
        }
        do {
            try config.save(to: configPath)
            let prof = profile.map { " [\($0)]" } ?? ""
            print("Added \(isRegex ? "pattern" : "domain") '\(rule)' -> \(browser)\(prof)")
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "remove", "rm":
        guard let rule = rest.first, !rule.isEmpty else {
            fputs("usage: browter remove <domain-or-pattern>\n", stderr)
            return 2
        }
        do {
            var config = try BrowterConfig.load(from: configPath)
            let count = config.removeRule(rule)
            if count == 0 {
                fputs("Not found: \(rule)\n", stderr)
                return 1
            }
            try config.save(to: configPath)
            print("Removed \(count) matching rule(s) for '\(rule)'")
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "profiles":
        let discovered = discoverBrowserProfiles()
        if discovered.isEmpty {
            print("No Chromium or Firefox profiles found.")
            return 0
        }
        for entry in discovered {
            print("\(entry.browser) (\(entry.bundleID)):")
            for p in entry.profiles {
                if p.directory == p.displayName {
                    print("  \(p.directory)")
                } else {
                    print("  \(p.directory)  (\(p.displayName))")
                }
            }
        }
        return 0

    case "edit":
        if !FileManager.default.fileExists(atPath: configPath) {
            fputs("Config not found at \(configPath). Run 'browter init' first.\n", stderr)
            return 1
        }
        let editor = ProcessInfo.processInfo.environment["VISUAL"]
            ?? ProcessInfo.processInfo.environment["EDITOR"]
        let process = Process()
        if let editor, !editor.isEmpty {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, configPath]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-t", configPath]
        }
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "check", "--check":
        guard FileManager.default.fileExists(atPath: configPath) else {
            fputs("error: config file not found at \(configPath) (run 'browter init')\n", stderr)
            return 1
        }
        do {
            let config = try BrowterConfig.load(from: configPath)
            let router = CompiledRouter(config: config)
            print("Config OK: \(configPath)")
            print("  fallback: \(config.fallback) -> \(resolveApplication(for: config.fallback)?.url.path ?? "NOT FOUND")")
            print("  unwrapSafeLinks: \(config.unwrapSafeLinks)")
            print("  routes: \(router.routes.count)")
            for route in router.routes {
                let resolved = resolveApplication(for: route.browser)?.url.path ?? "NOT FOUND"
                let prof = route.profile.map { " [\($0)]" } ?? ""
                print("    [\(route.index)] \(route.browser)\(prof) -> \(resolved) (\(route.regexes.count) rules, \(route.hints.count) hints)")
            }
            for warning in router.warnings {
                fputs("warning: \(warning)\n", stderr)
            }
            return router.warnings.isEmpty ? 0 : 1
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }

    case "test", "--test":
        guard let testURL = rest.first, !testURL.isEmpty else {
            fputs("usage: browter test <url>\n", stderr)
            return 2
        }
        let config = (try? BrowterConfig.load(from: configPath)) ?? BrowterConfig()
        let router = CompiledRouter(config: config)
        let decision = router.decide(rawURL: testURL)
        if decision.matchURL != testURL {
            print("unwrapped: \(decision.matchURL)")
        }
        switch decision {
        case .route(let route, _):
            let prof = route.profile.map { " profile=\($0)" } ?? ""
            print("match: route[\(route.index)] browser=\(route.browser)\(prof)")
        case .fallback(let browser, _):
            print("match: fallback browser=\(browser)")
        }
        return 0

    default:
        return nil
    }
}

// MARK: - Entry Point

let configPath = resolveConfigPath()
if let exitCode = runCLI(args: Array(CommandLine.arguments.dropFirst()), configPath: configPath) {
    exit(exitCode)
}

let app = NSApplication.shared
let coordinator = RouteCoordinator(configPath: configPath)
let delegate = AppDelegate(coordinator: coordinator)
app.delegate = delegate
app.run()
