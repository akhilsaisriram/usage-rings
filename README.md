# Usage Rings

Personal native macOS menu bar app for Claude and Codex subscription quotas. No packages, API key, server, or model calls required.

## Build and run

Requires an Apple Silicon Mac with macOS 13 or newer, Apple command-line developer tools (`xcode-select --install`), and Claude Code and Codex signed into your own subscriptions.

```sh
git clone https://github.com/akhilsaisriram/usage-rings.git
cd usage-rings
zsh build.sh
open "build/Usage Rings.app"
```

The menu bar shows **Cl** (Claude) and **Cx** (Codex), each with concentric rings: **outer = session**, **inner = weekly**. Percentages appear as **session / weekly**, without words, for example `Cl 39% / 82%`. Each ring uses its provider color below 80%, orange from 80%, and red from 95%. Unavailable limits have no ring or percentage; a weekly-only Codex account shows `Cx 26%`. Click for all quota windows returned by the provider, percentages used/remaining, reset countdowns and dates, credits where supplied, and connection status.

Refresh runs every five minutes, on wake, and manually. Errors replace current numbers so old values cannot appear live. Unavailable data uses a dash, never zero. No login-item changes are made; add the built app in System Settings → General → Login Items if desired. Command-drag its menu bar item to reposition it.

## Account connections

- **Codex:** existing ChatGPT sign-in via `~/.local/bin/codex app-server`, using the documented initialize handshake and `account/rateLimits/read`. No model sessions are created. Run `codex login` in Terminal if needed.
- **Claude:** reads `~/.claude/.credentials.json`, or the `Claude Code-credentials` Keychain item. Background reads never show a Keychain prompt. **Connect Claude** explicitly allows macOS to ask for access. Run `claude auth login` in Terminal if no subscription token is present. Browser login alone does not establish a readable terminal login.
- Claude usage uses `https://api.anthropic.com/api/oauth/usage` with the existing access token. This is an internal endpoint used by usage trackers, not a documented stable public API, and can change. Credentials are never refreshed or rewritten by this app; Claude Code owns login renewal.
- Claude requests use an ephemeral network session with URL caching, cookies, and credential storage disabled. Each session is invalidated after its request. This does not remove any caches created by older versions or control Codex CLI's own storage.
- No tokens, cookie values, account IDs, or emails are logged or persisted. No browser cookie extraction. Diagnostic output includes only quota data and connection errors.
- Absolute message/token allowances are displayed only if supplied by the provider; a percentage is not converted into an invented message count. Credit balances retain provider units.

## Checks

```sh
"build/Usage Rings.app/Contents/MacOS/UsageRings" --self-test
"build/Usage Rings.app/Contents/MacOS/UsageRings" --diagnose
open "build/Usage Rings.app" --args --preview
```

`--diagnose --connect-claude` permits a foreground Keychain prompt. Rebuilding changes the ad-hoc signature and may require granting access again. No Git actions are part of this project.

Local builds enable hardened runtime and verify their ad-hoc signature. They are not Developer ID signed or Apple notarized; macOS may still block downloaded builds.

Sources: [Codex app server](https://learn.chatgpt.com/docs/app-server), [Claude status-line quota fields](https://code.claude.com/docs/en/statusline), [CodexBar Claude connection implementation notes](https://github.com/steipete/CodexBar/blob/main/docs/claude.md).
