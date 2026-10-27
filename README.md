# Usage Rings

Personal native macOS menu bar app for Claude and Codex subscription quotas. No hosted server, API key, or model prompts required.

## Build and run

Requires an Apple Silicon Mac with macOS 13 or newer, Apple command-line developer tools (`xcode-select --install`), and Claude Code and Codex signed into your own subscriptions.

```sh
git clone https://github.com/akhilsaisriram/usage-rings.git
cd usage-rings
zsh build.sh
open "build/Usage Rings.app"
```

The menu bar shows **Cl** (Claude) and **Cx** (Codex), each with concentric rings: **outer = session**, **inner = weekly**. Percentages appear as **session / weekly**, without words, for example `Cl 39% / 82%`. Each ring uses its provider color below 80%, orange from 80%, and red from 95%. Unavailable limits have no ring or percentage; a weekly-only Codex account shows `Cx 26%`. Click for all quota windows returned by the provider, percentages used/remaining, reset countdowns and dates, credits where supplied, and connection status.

The widget checks the local Claude feed every 60 seconds; this does not make a network request. Feed setup configures Claude Code's `statusLine.refreshInterval` to 300 seconds, rerunning the local collector every five minutes in addition to normal events. This does not guarantee Claude has fetched newer account limits. Codex stays connected and consumes available notifications. Startup, waking, and manual Refresh read a Codex snapshot through that connection. There is no scheduled remote usage polling by the widget. `~` marks last-known values older than 10 minutes or past a reported reset. Timestamps mean received locally, not guaranteed fresh account-wide usage. Unavailable data uses a dash, never zero. No login-item changes are made; add the built app in System Settings → General → Login Items if desired. Command-drag its menu bar item to reposition it.

## Account connections

- **Claude:** uses the documented Claude Code status-line payload. Select **Set up Claude feed** in the app, or run the setup command below. It installs a stable helper in `~/Library/Application Support/Usage Rings/UsageRingsFeed` and adds its command to `~/.claude/settings.json`. Existing unrelated status lines are refused rather than overwritten. Settings are backed up privately before the first setup. If you already have a status-line script, invoke the helper with `--collect-claude` from your script and pass the same stdin JSON to it; preserve your script's normal output.
- The collector saves only allowed session/weekly/spend-limit percentages, reset timestamps, and its local receipt time in `claude-usage.json`, with owner-only permissions. It does not save messages, transcript paths, tokens, or the full status-line payload. It does not read Keychain or Claude credentials and makes no direct Claude API request.
- Use Claude Code after setup. Its settings normally reload automatically; restart Claude Code if the feed remains absent. The status-line fields may be absent before the first model response. Installing a custom status line can hide some built-in Claude footer hints; the helper prints a small usage line instead.
- Claude's browser/desktop-only activity may not appear until Claude Code receives updated quota data. Missing payloads retain the last known reading rather than writing a fake zero. Model-specific limits not supplied by the documented status-line payload cannot be displayed.
- **Codex:** owns one `~/.local/bin/codex app-server` process and uses its documented initialize handshake, `account/rateLimits/read`, and `account/rateLimits/updated`. The widget does not read Codex tokens. The CLI still performs its own authentication/network operations. A separate app-server connection is not guaranteed to receive every change caused by other apps immediately; use Refresh for a new snapshot.
- No model prompts, browser-cookie extraction, or token logging. The previous direct Claude OAuth reader has been removed. Old versions' caches and Keychain permissions are not deleted by this change.
- To disable the Claude feed, remove only its `statusLine` setting (or restore your prior setting). The private backup is `~/Library/Application Support/Usage Rings/claude-settings-before-feed.json`; do not blindly restore it over newer unrelated settings.

## Checks

```sh
"build/Usage Rings.app/Contents/MacOS/UsageRings" --self-test
"build/Usage Rings.app/Contents/MacOS/UsageRings" --setup-claude-feed
"build/Usage Rings.app/Contents/MacOS/UsageRings" --diagnose
python3 Tests/run.py
open "build/Usage Rings.app" --args --preview
```

`--diagnose` prints quota data and source errors only. `Tests/run.py` uses a fake local CLI and temporary files; it does not access account credentials or the network. No Git actions are part of the build.

Local builds enable hardened runtime and verify their ad-hoc signature. They are not Developer ID signed or Apple notarized; macOS may still block downloaded builds.

Sources: [Codex app server](https://learn.chatgpt.com/docs/app-server), [Claude status-line quota fields](https://code.claude.com/docs/en/statusline).
