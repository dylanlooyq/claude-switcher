# Claude Switcher

A Windows tray app that switches [Claude Code](https://code.claude.com) between sources - your personal
claude.ai login and one or more LLM gateways - without hand-editing `settings.json`.

Each source is a **profile**: a set of environment variables (usually `ANTHROPIC_BASE_URL` plus
`ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`) and an optional model. Switching rewrites the `env` and
`model` entries in `~/.claude/settings.json` and leaves everything else in that file alone. A profile with
no env vars (Personal) just clears the gateway settings so Claude Code falls back to your normal login.

Requires Windows and PowerShell 5.1 (built in). Nothing to install.

## Start it

Double-click `start-switcher.vbs`. A coloured dot appears in the system tray (click `^` if it is hidden)
and the window opens.

- **Left-click the dot** - open the window: one card per source with live status and usage.
- **Right-click the dot** - small menu (open, quick switch, exit).
- Closing the window only hides it. Use **Exit** in the right-click menu to quit.
- Starting it again while it is running just brings the window up.

## First-time setup

1. Click **Edit...** on a gateway card (or **Edit profiles...**).
2. Enter one `KEY=VALUE` per line, for example:
   ```
   ANTHROPIC_BASE_URL=https://your-gateway.example.com
   ANTHROPIC_AUTH_TOKEN=your-token
   ```
   Use `ANTHROPIC_API_KEY` instead if your gateway wants the `x-api-key` header. Set **Model** if it needs one.
3. Click **Save**, then **Switch to this**.
4. **Restart any running Claude Code sessions** - they only read settings at startup.

The starter profiles are `personal`, `ica` and `rise`; rename them however you like.

## What the window does

| Button | What it does |
|---|---|
| **Switch to this** | Makes that source active (writes `settings.json`, keeps a backup). |
| **Fix...** | Troubleshooter for a source that is not working. Greyed out when it is live. |
| **Test connections...** | Sends a 1-token request to each source and shows the full reply or error. |
| **Check usage...** | Personal: session and weekly limits with reset times. Gateways: key spend and budgets. |

**Fix...** finds and offers fixes for the usual gateway problems: a model name the gateway does not accept
(it asks the gateway which models your key can use and tests each one), the credential sent in the wrong
header, and a base URL that wrongly ends in `/v1`. Nothing is changed until you press **Apply fix**.

## Command line

```powershell
.\claude-switcher.ps1 -List                 # profiles, and which is active
.\claude-switcher.ps1 -Use personal         # switch and exit
.\claude-switcher.ps1 -Test all             # is each source live? (exit code 1 if any fail)
.\claude-switcher.ps1 -Usage all            # usage, limits and resets
.\claude-switcher.ps1 -Silent               # start in the tray without opening the window
```

To start at login, put a shortcut in `shell:startup` that runs:
`powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\to\claude-switcher.ps1" -Silent`

## Where things live

| Path | Contents |
|---|---|
| `%APPDATA%\claude-switcher\profiles.json` | Your profiles, **including tokens in plain text**. |
| `%APPDATA%\claude-switcher\backups\` | Your last 20 `settings.json` versions, one per switch. |
| `%APPDATA%\claude-switcher\error.log` | Only written if something goes wrong. |

Tokens are also in `~/.claude/settings.json` while that source is active. Never commit or share these files;
the repo's `.gitignore` excludes them as a safety net.

## Good to know

- **Overrides.** A project-level `.claude/settings.json`, or `ANTHROPIC_*` variables set in Windows itself,
  override what the switcher writes. If a switch does not seem to take effect, check those first.
- **Personal usage** uses the same undocumented Anthropic endpoint that Claude Code's `/usage` reads, with your
  login token from `~/.claude/.credentials.json`. The token is held in memory only and sent only to
  `api.anthropic.com`. The endpoint rate-limits itself, so the app reuses a fresh result and falls back to the
  last known figures.
- **Gateway usage** assumes a LiteLLM-style gateway (spend headers, `/key/info`, `/team/info`). Gateways that
  do not expose those still show connection status, just less usage detail.
- The tester and troubleshooter make real requests to your gateways (1 token each).
