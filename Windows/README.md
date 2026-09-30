# Claude Switcher

A Windows tray app that switches [Claude Code](https://code.claude.com) between sources - your personal
claude.ai login and one or more LLM gateways - without hand-editing `settings.json`.

Each source is a **profile**: a set of environment variables (usually `ANTHROPIC_BASE_URL` plus
`ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`) and an optional model. Switching rewrites the `env` and
`model` entries in `~/.claude/settings.json` and leaves everything else in that file alone. It also mirrors
the same env vars into your Windows **User** environment variables, so other tools that read
`$env:ANTHROPIC_API_KEY` etc. directly see the switch too. A profile with no env vars (Personal) just
clears the gateway settings so Claude Code falls back to your normal login.

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
4. **Restart any running Claude Code sessions or terminals** - settings.json is only read at startup, and
   existing terminals keep the environment variables they started with. Editors such as VS Code are the
   same: see **Stale editors** below.

The starter profiles are `personal`, `personal (2nd account)`, `ica` and `rise`; rename them however you like.

### Using a second claude.ai login

"Personal (2nd account)" is a second personal profile, already set up with its own
`CLAUDE_CONFIG_DIR` (a Claude Code setting that points at a private config folder under
`%APPDATA%\claude-switcher\accounts\personal2`) so it never touches your main login. To use it:

1. **Switch to this** on the "Personal (2nd account)" card.
2. Restart any running Claude Code terminals, then open a new one and run `claude`, then `/login`
   and sign in with the second account.

From then on, switching between "Personal Claude" and "Personal (2nd account)" swaps between the
two logins, each with its own credentials and usage.

You can add further profiles (a 3rd account, another gateway) from **Edit profiles...** with the
**Add profile** / **Remove** buttons next to the list.

## What the window does

| Button | What it does |
|---|---|
| **Switch to this** | Makes that source active (writes `settings.json`, keeps a backup). |
| **Fix...** | Troubleshooter for a source that is not working. Greyed out when it is live. |
| **Test connections...** | Sends a 1-token request to each source and shows the full reply or error. |
| **Check usage...** | Personal: session and weekly limits with reset times. Gateways: key spend and budgets. |
| **Check for updates...** | Lists each source's available models and flags a newer Sonnet/Opus/Haiku than the one you have pinned. |

**Fix...** finds and offers fixes for the usual gateway problems: a model name the gateway does not accept
(it asks the gateway which models your key can use and tests each one), the credential sent in the wrong
header, and a base URL that wrongly ends in `/v1`. Nothing is changed until you press **Apply fix**.

**Check for updates...** only reads each source's model list (the gateway's `/v1/models`, or Anthropic's for
a Personal login) and compares it to the model you have pinned - it does not test the candidate model first,
so nothing changes until you pick a source and press **Update**, and it is worth running **Test connections...**
again afterwards. Sources with no pinned model (Claude Code's own default) or a custom, non-Claude model name
are shown as such rather than checked.

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

Tokens are also in `~/.claude/settings.json` while that source is active, and in your Windows **User**
environment variables (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`) - check
`Environment Variables` in Windows settings if you want to see or clear them by hand. Never commit or
share these files; the repo's `.gitignore` excludes them as a safety net.

A personal profile with a `CLAUDE_CONFIG_DIR` env var (like "Personal (2nd account)") keeps its own
login and settings under `%APPDATA%\claude-switcher\accounts\<profile>\` instead of `~/.claude`.
`CLAUDE_CONFIG_DIR` only ever lives in the Windows **User** environment variables, never in
`settings.json` - Claude Code needs it before it can even find that file.

## Good to know

- **Stale editors.** Windows gives each app a copy of the environment variables when it starts, and a switch
  can't change that copy. So VS Code, started while a gateway was active, keeps that gateway's `ANTHROPIC_*`
  values, and Claude Code inside it keeps using them (and showing that gateway's models) even after you switch
  back to Personal. settings.json can override a variable but not remove one. The window shows a yellow banner
  when it spots this in VS Code, VS Code Insiders, Cursor or Windsurf, and `-List` / `-Use` print the same
  warning. The fix is to quit the editor fully (**File > Exit**; Reload Window is not enough) and start it again.
- **Overrides.** A project-level `.claude/settings.json`, or a **Machine**-level (system-wide) `ANTHROPIC_*`
  variable, override what the switcher writes. If a switch does not seem to take effect, check those first.
- **Personal usage** uses the same undocumented Anthropic endpoint that Claude Code's `/usage` reads, with your
  login token from `~/.claude/.credentials.json`. The token is held in memory only and sent only to
  `api.anthropic.com`. The endpoint rate-limits itself, so the app reuses a fresh result and falls back to the
  last known figures.
- **Gateway usage** assumes a LiteLLM-style gateway (spend headers, `/key/info`, `/team/info`). Gateways that
  do not expose those still show connection status, just less usage detail.
- The tester and troubleshooter make real requests to your gateways (1 token each).
