# Browter

Lightweight, background-only macOS app that acts as your default browser and routes each link to the right browser or profile. No window, no Dock icon, no menu bar icon, no network calls.

## Features

- **Instant native handoff:** written in Swift with zero external dependencies.
- **Per-browser and per-profile routing:** supports Chromium profiles (`--profile-directory`) and Firefox/Zen profiles (`-P`).
- **Fast Chrome tab reuse:** when Google Chrome is already running with a matching profile window, adds a tab via AppleScript (`chromium-tab.applescript`) instead of spawning a new Chrome process.
- **Hot-reloading JSON config:** edit `~/.config/browter/config.json` and the next click picks it up automatically.
- **SafeLinks-aware:** unwraps Microsoft Teams and Outlook safe-links to choose the right browser while still opening the original wrapper URL so the security check runs.
- **`.webloc` support:** extracts the destination URL from macOS `.webloc` files before routing.

## Install

### Homebrew (once published)

```sh
brew install --cask marsidev/tap/browter
```

If the release is not notarized with an Apple Developer ID, clear the quarantine attribute after installing:

```sh
xattr -dr com.apple.quarantine /Applications/Browter.app
```

### Build from source

Requires macOS 13+ and Swift / Xcode Command Line Tools:

```sh
git clone https://github.com/marsidev/browter.git
cd browter
./build.sh
```

This builds `build/Browter.app`, ad-hoc signs it, installs it to `~/Applications/Browter.app`, and registers it with Launch Services.

## Configuration

Run `browter init` (or copy [config.example.json](config.example.json) to `~/.config/browter/config.json`).

Example `~/.config/browter/config.json` (includes `$schema` for autocompletion and validation in VS Code, Cursor, Zed, and JetBrains):

```json
{
  "$schema": "https://raw.githubusercontent.com/marsidev/browter/main/config.schema.json",
  "fallback": "com.brave.Browser",
  "unwrapSafeLinks": true,
  "routes": [
    {
      "browser": "com.google.Chrome",
      "profile": "Profile 1",
      "domains": [
        "github.com/acme",
        "*.azure.com",
        ".microsoft"
      ],
      "patterns": [
        "^https?://(login|sts)\\.windows\\.net(:[0-9]+)?(/|$|\\?|#)"
      ]
    }
  ]
}
```

### Fields

- **`fallback`** (optional, default `"com.apple.Safari"`): browser for unmatched URLs. Accepts a bundle ID (e.g. `"com.brave.Browser"`), an app name (`"Brave Browser"`), or a full `.app` path.
- **`unwrapSafeLinks`** (optional, default `true`): inspect the destination URL inside Microsoft Teams/Outlook safe-links for routing, then open the original wrapper URL.
- **`routes`**: evaluated top-to-bottom; first match wins.
  - **`browser`** (required): bundle ID, app name, or `.app` path.
  - **`profile`** (optional): Chrome/Chromium profile directory name (e.g. `"Default"`, `"Profile 1"`) or Firefox profile name.
  - **`domains`** (optional): human-friendly domain/path rules:
    - `"example.com"` - exact host
    - `"*.example.com"` - `example.com` and any subdomain
    - `".microsoft"` - any host ending in `.microsoft`
    - `"github.com/acme"` - host + path prefix
  - **`patterns`** (optional): case-insensitive regular expressions matched against the full URL.
  - **`hints`** (optional): tab-URL substrings used by AppleScript to find an existing Chrome profile window. Auto-derived from `domains` when omitted.
  - **`useAppleScript`** (optional, default `true`): set to `false` to always pass `--profile-directory` directly to Chrome instead of using AppleScript.

Override the config path with `BROWTER_CONFIG=/path/to/config.json` or `defaults write dev.marsidev.browter configPath /path/to/config.json`.

## Set as default browser

System Settings -> Desktop & Dock -> Default web browser -> **Browter**.
Pick any other browser there to switch back at any time.

## CLI

When installed via Homebrew (or `./build.sh` with `~/.local/bin` on `$PATH`), the `browter` CLI manages your config directly:

```sh
browter init                                                      # create starter ~/.config/browter/config.json
browter profiles                                                  # list installed Chrome/Brave/Edge/Firefox profiles
browter add "github.com/acme" --browser "Google Chrome" --profile "Profile 1"
browter add "^https://sso\\.acme\\.com" --browser "Google Chrome" --profile "Profile 1" --regex
browter remove "github.com/acme"
browter list                                                      # print current fallback and routes
browter edit                                                      # open config.json in $EDITOR
browter check                                                     # validate config and resolved browsers
browter test "https://github.com/acme/repo"                       # dry-run a URL without opening it
```

## Debugging

Enable timing logs (`~/Library/Logs/Browter.log`):

```sh
defaults write dev.marsidev.browter debug -bool true
pkill -x Browter
```

Turn logging off:

```sh
defaults delete dev.marsidev.browter debug
pkill -x Browter
```

> Note: debug logs record full URLs (including query parameters) to `~/Library/Logs/Browter.log`. Leave debug logging off during normal use.

## License

MIT
