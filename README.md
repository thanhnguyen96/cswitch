# cswitch

Switch between Claude Desktop accounts on Windows without logging out and back in.

> **Unofficial.** Not affiliated with or endorsed by Anthropic. It works by managing
> Claude Desktop's local data folder, so a future Claude update could break it.

- Windows 10/11, **Claude Desktop from the Microsoft Store** (the MSIX build)
- PowerShell 5.1+ (built in). No admin rights, no Node, no extra downloads.

## Install

```powershell
irm https://raw.githubusercontent.com/thanhnguyen96/cswitch/HEAD/install.ps1 | iex
```

Pin a version with `$env:CSWITCH_REF = 'v0.1.0'` before running the line above.

Prefer to read it first? Download, inspect, then run:

```powershell
irm https://raw.githubusercontent.com/thanhnguyen96/cswitch/HEAD/install.ps1 -OutFile install.ps1
notepad install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Open a new terminal afterwards so `cswitch` is on your `PATH`.

## First use

```powershell
cswitch import work     # save the account Claude is logged in to right now
cswitch add personal    # Claude restarts empty: log in to the second account once
cswitch work            # switch back (Claude restarts)
```

## Web UI

```powershell
cswitch ui              # opens http://127.0.0.1:47821
```

Or open **cswitch** from the Start menu. The UI server runs hidden in the background, only
listens on `127.0.0.1`, and shows a **tray icon** while it runs:

- left-click: open the web UI
- right-click: switch account, toggle *Start with Windows*, or *Quit cswitch*

It keeps running until you quit it from the tray, press **Stop server** in the web UI, or run
`cswitch ui stop`. `cswitch autostart on` starts it (tray only, no browser) when you sign in.
Port taken? `cswitch ui --port 48000`, or set `CSWITCH_PORT` for good.

## Commands

| Command | |
|---|---|
| `cswitch <alias>` | switch to a profile (restarts Claude) |
| `cswitch list` | list profiles, `*` = active |
| `cswitch import <alias>` | save Claude's current login as a profile |
| `cswitch add <alias>` | new empty profile, log in in the window that opens |
| `cswitch rename <old> <new>` | rename a profile |
| `cswitch remove <alias> [-y]` | delete a profile and its saved login |
| `cswitch ui [--port <n>]` / `cswitch ui stop` | web UI + tray icon |
| `cswitch autostart on\|off` | start the tray icon when you sign in to Windows |
| `cswitch update` | install the latest version (profiles are kept) |
| `cswitch uninstall [--purge]` | remove cswitch (see below) |

## How it works

Claude Desktop keeps its whole session (login, cookies, settings, Cowork data) in
`%LOCALAPPDATA%\Claude-Data\claude_<id>`. cswitch moves that folder into
`%LOCALAPPDATA%\cswitch\profiles\<alias>` and replaces it with a **junction** pointing at
the active profile. Switching stops Claude, retargets the junction and starts Claude again.

Because Claude always opens the same path, logins finished in the browser (which relaunch
Claude through a `claude://` link) are saved into the active profile too. The bundled
Claude Code binaries (~600 MB) are shared by all profiles through another junction.

Things that do **not** work:

- A junction at `%APPDATA%\Claude`, or `--user-data-dir`: the Store build ignores the first,
  and browser logins bypass the second.
- Copying a profile to another PC or Windows user: the login is encrypted with Windows DPAPI
  for this user, so it will ask you to log in again.

## Uninstall

```powershell
cswitch uninstall           # keeps other profiles in %LOCALAPPDATA%\cswitch\profiles
cswitch uninstall --purge   # also deletes every profile except the active one
```

The active profile is handed back to Claude as its normal data folder, so Claude stays
logged in to that account. cswitch is removed from `PATH` and the Start menu.

## Development

```powershell
$env:CSWITCH_SOURCE = (Get-Location).Path; .\install.ps1   # install from this checkout
powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox.ps1
```

`tests\sandbox.ps1` runs install, every command, the web API, update and uninstall inside a
temp folder. It never touches your real profiles or starts or stops Claude.
Keep the `.ps1` files ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
