# cswitch - switch Claude Desktop (Microsoft Store build) accounts without logging out.
# Unofficial; not affiliated with Anthropic.
#
# How it works
#   Claude keeps its whole session (login, cookies, settings) in one folder:
#     %LOCALAPPDATA%\Claude-Data\claude_<publisherId>          ("live" folder)
#   cswitch turns that folder into a junction pointing at one profile folder:
#     %LOCALAPPDATA%\cswitch\profiles\<alias>
#   Switching = stop Claude, retarget the junction, start Claude.
#   The app always resolves the same path (even when a browser login relaunches
#   it via claude://), so every login lands in the active profile.
#   Big regenerable folders (bundled Claude Code, ~600 MB) are shared between
#   profiles via junctions into %LOCALAPPDATA%\cswitch\shared.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$ErrorActionPreference = 'Stop'
$Version     = '0.1.0'
$Root        = Join-Path $env:LOCALAPPDATA 'cswitch'
$Profiles    = Join-Path $Root 'profiles'
$Shared      = Join-Path $Root 'shared'
$SharedDirs  = @('claude-code')
$RepoRaw     = 'https://raw.githubusercontent.com/thanhnguyen96/cswitch'
$IdleMinutes = 30
$DefaultPort = 47821
$UiState     = Join-Path $Root 'ui.json'   # port + token of the running UI server

# ---------------------------------------------------------------- Claude app

$script:Pkg = $null
function Get-ClaudePackage {
    if ($script:Pkg) { return $script:Pkg }
    $p = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Publisher -match 'Anthropic' } |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $p) { throw 'Claude Desktop (Microsoft Store build) is not installed for this Windows user.' }
    $script:Pkg = $p
    return $p
}

function Get-LivePath {
    $p = Get-ClaudePackage
    return Join-Path $env:LOCALAPPDATA ("Claude-Data\claude_" + $p.PublisherId)
}

function Get-ClaudeProcesses {
    $pfn = (Get-ClaudePackage).PackageFamilyName -replace '_.*$', ''
    @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
        Where-Object { $_.ExecutablePath -match ('\\WindowsApps\\' + [regex]::Escape($pfn) + '_') })
}

function Test-ClaudeRunning { return (Get-ClaudeProcesses).Count -gt 0 }

function Stop-Claude {
    if ($env:CSWITCH_NO_APP) { return $false }   # tests: never touch the real app
    $procs = Get-ClaudeProcesses
    if ($procs.Count -eq 0) { return $false }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Test-ClaudeRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    if (Test-ClaudeRunning) { throw 'Could not stop Claude. Quit it from the tray icon and try again.' }
    Start-Sleep -Milliseconds 500   # let the OS release file locks
    return $true
}

function Start-Claude {
    # Launch like the Start menu does. The claude-desktop.exe alias would share
    # this console and print the app's log output into the terminal.
    if ($env:CSWITCH_NO_APP) { return }
    $aumid = (Get-ClaudePackage).PackageFamilyName + '!Claude'
    Start-Process 'explorer.exe' -ArgumentList "shell:AppsFolder\$aumid"
}

# ---------------------------------------------------------------- filesystem

function Get-Junction($path) {
    $i = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $i) { return @{ Exists = $false } }
    if ($i.LinkType -eq 'Junction') {
        return @{ Exists = $true; Junction = $true; Target = ([string]@($i.Target)[0]).TrimEnd('\') }
    }
    return @{ Exists = $true; Junction = $false }
}

function Remove-Junction($path) { [IO.Directory]::Delete($path) }   # removes the link only

function New-Junction($path, $target) {
    New-Item -ItemType Junction -Path $path -Target $target | Out-Null
}

function Remove-Tree($path) {
    # rmdir /s does not follow junctions, so shared data is never touched.
    if (Test-Path -LiteralPath $path) { cmd /c rmdir /s /q "`"$path`"" | Out-Null }
    if (Test-Path -LiteralPath $path) { throw "Could not delete $path (files in use?)." }
}

function Merge-Into($from, $to) {
    if (-not (Test-Path -LiteralPath $to)) { Move-Item -LiteralPath $from -Destination $to; return }
    robocopy $from $to /E /MOVE /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed ($LASTEXITCODE): $from -> $to" }
    Remove-Tree $from
}

# Make every shared dir inside a profile a junction into $Shared.
function Sync-Shared($dir) {
    New-Item -ItemType Directory -Force -Path $Shared | Out-Null
    foreach ($s in $SharedDirs) {
        $target = Join-Path $Shared $s
        $link = Join-Path $dir $s
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $j = Get-Junction $link
        if ($j.Exists -and $j.Junction) {
            if ($j.Target -eq $target) { continue }
            Remove-Junction $link
        } elseif ($j.Exists) {
            Merge-Into $link $target
        }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        New-Junction $link $target
    }
}

# ---------------------------------------------------------------- profiles

function Assert-Alias($name) {
    if (-not $name) { throw 'Alias is required.' }
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$') {
        throw "Alias '$name' is invalid. Use letters, digits, . _ - (max 40 chars)."
    }
}

function Get-ProfileDir($name) { return Join-Path $Profiles $name }

function Assert-Exists($name) {
    Assert-Alias $name
    if (-not (Test-Path -LiteralPath (Get-ProfileDir $name))) {
        $have = @(Get-ProfileNames)
        $list = if ($have.Count) { $have -join ', ' } else { '(none yet)' }
        throw "No profile '$name'. Have: $list"
    }
}

function Get-ProfileNames {
    if (-not (Test-Path $Profiles)) { return @() }
    @(Get-ChildItem -LiteralPath $Profiles -Directory | Sort-Object Name | ForEach-Object Name)
}

function Test-LoggedIn($dir) {
    # Login is stored as oauth:tokenCache* or as a session cookie; both write
    # lastKnownAccountUuid. Only key names are checked, never values.
    $cfg = Join-Path $dir 'config.json'
    if (-not (Test-Path -LiteralPath $cfg)) { return $false }
    return [bool]((Get-Content -LiteralPath $cfg -Raw) -match '"(oauth:tokenCache|lastKnownAccountUuid)"')
}

function Get-Active {
    $j = Get-Junction (Get-LivePath)
    if (-not ($j.Exists -and $j.Junction)) { return $null }
    $prefix = $Profiles.TrimEnd('\') + '\'
    if ($j.Target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $j.Target.Substring($prefix.Length)
    }
    return $null
}

# 'managed' | 'unmanaged' (real folder, not imported) | 'missing' | 'foreign' (junction elsewhere)
function Get-LiveState {
    $j = Get-Junction (Get-LivePath)
    if (-not $j.Exists) { return 'missing' }
    if (-not $j.Junction) { return 'unmanaged' }
    if (Get-Active) { return 'managed' }
    return 'foreign'
}

function Set-Active($dir) {
    $live = Get-LivePath
    $j = Get-Junction $live
    if ($j.Exists -and -not $j.Junction) {
        throw "Claude's data folder is not managed by cswitch yet. Save the current login first: cswitch import <alias>"
    }
    if ($j.Exists) { Remove-Junction $live }
    New-Item -ItemType Directory -Force -Path (Split-Path $live) | Out-Null
    New-Junction $live $dir
}

function Get-Status {
    $active = Get-Active
    $items = @(Get-ProfileNames | ForEach-Object {
        [ordered]@{ name = $_; active = ($_ -eq $active); loggedIn = (Test-LoggedIn (Get-ProfileDir $_)) }
    })
    return [ordered]@{
        version   = $Version
        running   = (Test-ClaudeRunning)
        liveState = (Get-LiveState)
        active    = $active
        profiles  = $items
    }
}

# Each action returns a one-line message or throws.

function Invoke-Switch($name) {
    Assert-Exists $name
    $dir = Get-ProfileDir $name
    if ((Get-LiveState) -eq 'unmanaged') {
        throw "Claude's current login is not saved in any profile yet. Run: cswitch import <alias>"
    }
    Sync-Shared $dir
    $stopped = Stop-Claude
    Set-Active $dir
    Start-Claude
    if ($stopped) { return "Switched to '$name' (restarted Claude)." }
    return "Switched to '$name'."
}

function Invoke-Add($name) {
    Assert-Alias $name
    $dir = Get-ProfileDir $name
    if (Test-Path -LiteralPath $dir) { throw "Profile '$name' already exists." }
    if ((Get-LiveState) -eq 'unmanaged') {
        throw "Save the login Claude has now before adding another: cswitch import <alias>"
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Sync-Shared $dir
    Stop-Claude | Out-Null
    Set-Active $dir
    Start-Claude
    return "Profile '$name' created. Log in in the Claude window that just opened."
}

function Invoke-Import($name) {
    Assert-Alias $name
    $dir = Get-ProfileDir $name
    if (Test-Path -LiteralPath $dir) { throw "Profile '$name' already exists." }
    $state = Get-LiveState
    if ($state -eq 'managed') { throw "Claude's data is already managed (active profile: $(Get-Active))." }
    if ($state -eq 'foreign') { throw "Claude's data folder is a junction cswitch did not create: $((Get-Junction (Get-LivePath)).Target)" }
    if ($state -eq 'missing') { throw 'Claude has no data folder yet. Open Claude once, then run import.' }
    $wasRunning = Stop-Claude
    New-Item -ItemType Directory -Force -Path $Profiles | Out-Null
    Move-Item -LiteralPath (Get-LivePath) -Destination $dir   # same volume: instant rename, nothing lost
    Sync-Shared $dir
    Set-Active $dir
    if ($wasRunning) { Start-Claude }
    return "Saved the current Claude login as '$name'."
}

function Invoke-Rename($old, $new) {
    Assert-Exists $old
    Assert-Alias $new
    $newDir = Get-ProfileDir $new
    if (Test-Path -LiteralPath $newDir) { throw "Profile '$new' already exists." }
    $wasActive = (Get-Active) -eq $old
    if ($wasActive -and (Test-ClaudeRunning)) {
        throw "Profile '$old' is in use. Switch to another profile or quit Claude first."
    }
    if ($wasActive) { Remove-Junction (Get-LivePath) }
    Move-Item -LiteralPath (Get-ProfileDir $old) -Destination $newDir
    if ($wasActive) { Set-Active $newDir }
    return "Renamed '$old' -> '$new'."
}

function Invoke-Remove($name, [bool]$force) {
    Assert-Exists $name
    $wasActive = (Get-Active) -eq $name
    if ($wasActive -and (Test-ClaudeRunning)) {
        if (-not $force) { throw "Profile '$name' is in use. Switch away or quit Claude first, or pass -y." }
        Stop-Claude | Out-Null
    }
    if ($wasActive) { Remove-Junction (Get-LivePath) }
    $dir = Get-ProfileDir $name
    foreach ($s in $SharedDirs) {
        $j = Get-Junction (Join-Path $dir $s)
        if ($j.Junction) { Remove-Junction (Join-Path $dir $s) }
    }
    Remove-Tree $dir
    return "Deleted '$name'."
}

# Move the profiles of the old claude-use script (~\.local\bin\claude-use) here.
function Invoke-MigrateLegacy {
    $legacy = Join-Path $env:USERPROFILE '.local\bin\claude-use'
    if (-not (Test-Path (Join-Path $legacy 'profiles'))) { return }
    Write-Host "Migrating profiles from $legacy ..."
    $live = Get-LivePath
    $j = Get-Junction $live
    $activeName = $null
    if ($j.Exists -and $j.Junction -and $j.Target -like "$legacy\profiles\*") { $activeName = Split-Path $j.Target -Leaf }
    $wasRunning = Stop-Claude

    New-Item -ItemType Directory -Force -Path $Profiles, $Shared | Out-Null
    foreach ($s in $SharedDirs) {
        $old = Join-Path $legacy "shared\$s"
        if (Test-Path -LiteralPath $old) { Merge-Into $old (Join-Path $Shared $s) }
    }
    $left = 0
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $legacy 'profiles') -Directory)) {
        $dest = Get-ProfileDir $d.Name
        if (Test-Path -LiteralPath $dest) { Write-Host "  skip '$($d.Name)': already exists in $Profiles"; $left++; continue }
        Move-Item -LiteralPath $d.FullName -Destination $dest
        Sync-Shared $dest
        Write-Host "  moved '$($d.Name)'"
    }
    if ($activeName -and (Test-Path -LiteralPath (Get-ProfileDir $activeName))) { Set-Active (Get-ProfileDir $activeName) }

    foreach ($f in 'claude-use.ps1', 'claude-use.cmd') {
        Remove-Item -LiteralPath (Join-Path $env:USERPROFILE ".local\bin\$f") -Force -ErrorAction SilentlyContinue
    }
    if ($left -eq 0) { Remove-Tree $legacy } else { Write-Host "  left $legacy in place (see skipped profiles)." }
    if ($wasRunning) { Start-Claude }
}

function Invoke-Uninstall([bool]$purge) {
    $live = Get-LivePath
    $active = Get-Active
    $wasRunning = Stop-Claude
    if ($active) {
        # Give the active login back to Claude as a normal folder.
        $dir = Get-ProfileDir $active
        Remove-Junction $live
        foreach ($s in $SharedDirs) {
            $link = Join-Path $dir $s
            if ((Get-Junction $link).Junction) { Remove-Junction $link }
        }
        Move-Item -LiteralPath $dir -Destination $live
        foreach ($s in $SharedDirs) {
            if (Test-Path -LiteralPath (Join-Path $Shared $s)) { Merge-Into (Join-Path $Shared $s) (Join-Path $live $s) }
        }
        Write-Host "Claude keeps using '$active' as its normal login."
    }
    [Environment]::SetEnvironmentVariable('Path', ((
        [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
        Where-Object { $_ -and $_.TrimEnd('\') -ne (Join-Path $Root 'bin') }) -join ';'), 'User')
    Remove-Item -LiteralPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\cswitch.lnk') -Force -ErrorAction SilentlyContinue

    $rest = @(Get-ProfileNames)
    if ($purge -or $rest.Count -eq 0) {
        $targets = $Root
    } else {
        Write-Host "Kept other profiles in $Profiles ($($rest -join ', ')). Delete that folder yourself, or reinstall later to use them."
        $targets = @((Join-Path $Root 'app'), (Join-Path $Root 'bin'), $Shared)
    }
    # This script and its .cmd shim are still running, so delete after we exit.
    $cmds = ($targets | ForEach-Object { "rmdir /s /q `"$_`"" }) -join ' & '
    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c ping -n 3 127.0.0.1 >nul & $cmds"
    if ($wasRunning -and $active) { Start-Claude }
    return 'cswitch uninstalled.'
}

# ---------------------------------------------------------------- web UI

function Send-Response($stream, [int]$code, [string]$type, [byte[]]$body) {
    $reason = @{ 200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed' }[$code]
    $head = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`n" +
            "Cache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nX-Frame-Options: DENY`r`n" +
            "Referrer-Policy: no-referrer`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    if ($body.Length) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}

function Send-Json($stream, [int]$code, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 6 -Compress
    Send-Response $stream $code 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-Request($stream) {
    $stream.ReadTimeout = 5000
    $ms = New-Object IO.MemoryStream
    $buf = New-Object byte[] 8192
    $end = -1
    while ($end -lt 0) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0 -or $ms.Length -gt 65536) { return $null }
        $ms.Write($buf, 0, $n)
        $text = [Text.Encoding]::ASCII.GetString($ms.ToArray())   # 1 byte = 1 char, offsets stay valid
        $end = $text.IndexOf("`r`n`r`n")
    }
    $lines = $text.Substring(0, $end) -split "`r`n"
    $first = $lines[0] -split ' '
    $headers = @{}
    foreach ($l in ($lines | Select-Object -Skip 1)) {
        $i = $l.IndexOf(':')
        if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLowerInvariant()] = $l.Substring($i + 1).Trim() }
    }
    $len = 0
    if ($headers['content-length']) { $len = [int]$headers['content-length'] }
    if ($len -gt 65536) { return $null }
    $start = $end + 4
    while ($ms.Length - $start -lt $len) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
    }
    $all = $ms.ToArray()
    return @{
        Method  = $first[0]
        Path    = ($first[1] -split '\?')[0]
        Headers = $headers
        Body    = [Text.Encoding]::UTF8.GetString($all, $start, $len)
    }
}

# Returns $true when the UI asked to quit.
function Invoke-UiRequest($client, [int]$port, [string]$token, [byte[]]$html) {
    $stream = $client.GetStream()
    $req = Read-Request $stream
    if (-not $req) { return $false }

    # Block DNS rebinding: only our own origin may talk to us.
    if ($req.Headers['host'] -notin @("127.0.0.1:$port", "localhost:$port")) {
        Send-Json $stream 403 @{ error = 'bad host' }; return $false
    }
    if ($req.Method -eq 'GET' -and $req.Path -eq '/') {
        Send-Response $stream 200 'text/html; charset=utf-8' $html; return $false
    }
    if ($req.Method -eq 'GET' -and $req.Path -eq '/health') {
        Send-Json $stream 200 @{ app = 'cswitch'; version = $Version }; return $false
    }
    if (-not $req.Path.StartsWith('/api/')) { Send-Json $stream 404 @{ error = 'not found' }; return $false }
    # Custom header => browsers must preflight cross-origin calls, which we never allow.
    if ($req.Headers['x-cswitch-token'] -ne $token) { Send-Json $stream 403 @{ error = 'bad token' }; return $false }

    $action = $req.Path.Substring(5)
    if ($action -eq 'status' -and $req.Method -eq 'GET') { Send-Json $stream 200 (Get-Status); return $false }
    if ($req.Method -ne 'POST') { Send-Json $stream 405 @{ error = 'POST only' }; return $false }

    $b = $null
    if ($req.Body) { try { $b = $req.Body | ConvertFrom-Json } catch { } }
    try {
        switch ($action) {
            'switch' { $msg = Invoke-Switch $b.name }
            'add'    { $msg = Invoke-Add $b.name }
            'import' { $msg = Invoke-Import $b.name }
            'rename' { $msg = Invoke-Rename $b.name $b.newName }
            'remove' { $msg = Invoke-Remove $b.name $true }
            'quit'   { Send-Json $stream 200 @{ message = 'bye' }; return $true }
            default  { Send-Json $stream 404 @{ error = "unknown action '$action'" }; return $false }
        }
        Send-Json $stream 200 @{ message = $msg; status = (Get-Status) }
    } catch {
        Send-Json $stream 400 @{ error = $_.Exception.Message }
    }
    return $false
}

function Get-UiUrl([int]$port) { return "http://127.0.0.1:$port" }

# 'cswitch' | 'other' (port taken by another program) | 'free'
function Get-PortOwner([int]$port) {
    try {
        $r = Invoke-RestMethod -Uri "$(Get-UiUrl $port)/health" -TimeoutSec 2 -UseBasicParsing
        if ($r.app -eq 'cswitch') { return 'cswitch' }
        return 'other'
    } catch {
        if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count) { return 'other' }
        return 'free'
    }
}

# Serve the UI in this process until quit / idle timeout. Used by the hidden background process.
function Start-UiServer([int]$port) {
    $token = [guid]::NewGuid().ToString('N')
    # Embedding the token in the page is safe: other sites cannot read our pages
    # (same-origin policy + Host check), so only a page we served can call the API.
    $page = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ui.html')).Replace('__CSWITCH_TOKEN__', $token)
    $html = [Text.Encoding]::UTF8.GetBytes($page)
    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $port
    try { $listener.Start() } catch { throw "Port $port is already in use. Pick another: cswitch ui --port <n>" }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    ConvertTo-Json @{ port = $port; token = $token; pid = $PID } | Set-Content -LiteralPath $UiState -Encoding ascii
    $last = Get-Date
    try {
        while ($true) {
            if (-not $listener.Pending()) {
                if (((Get-Date) - $last).TotalMinutes -ge $IdleMinutes) { break }
                Start-Sleep -Milliseconds 100   # polling keeps Ctrl+C responsive
                continue
            }
            $client = $listener.AcceptTcpClient()
            $last = Get-Date
            $quit = $false
            try { $quit = Invoke-UiRequest $client $port $token $html } catch { } finally { $client.Close() }
            if ($quit) { break }
        }
    } finally {
        $listener.Stop()
        Remove-Item -LiteralPath $UiState -Force -ErrorAction SilentlyContinue
    }
}

# Make sure the UI server is running (start it hidden in the background), then open the browser.
function Open-Ui([int]$port, [bool]$noBrowser) {
    $url = Get-UiUrl $port
    $owner = Get-PortOwner $port
    if ($owner -eq 'other') {
        throw "Port $port is used by another program. Use another one: cswitch ui --port <n>  (or set CSWITCH_PORT)"
    }
    if ($owner -eq 'free') {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '__serve', $port)
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-PortOwner $port) -ne 'cswitch') {
            if ((Get-Date) -gt $deadline) { throw "The UI server did not start on port $port." }
            Start-Sleep -Milliseconds 300
        }
    }
    if (-not $noBrowser) { Start-Process $url }
    return "cswitch web UI: $url  (stops after $IdleMinutes idle minutes; cswitch ui stop to stop now)"
}

function Stop-Ui {
    if (-not (Test-Path -LiteralPath $UiState)) { return 'The web UI is not running.' }
    $s = Get-Content -LiteralPath $UiState -Raw | ConvertFrom-Json
    try {
        Invoke-RestMethod -Uri "$(Get-UiUrl $s.port)/api/quit" -Method Post -Body '{}' -TimeoutSec 3 -UseBasicParsing `
            -Headers @{ 'X-Cswitch-Token' = $s.token; 'Content-Type' = 'application/json' } | Out-Null
    } catch {
        Stop-Process -Id $s.pid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $UiState -Force -ErrorAction SilentlyContinue
    return 'Web UI stopped.'
}

function Get-UiPort($rest) {
    $i = [array]::IndexOf($rest, '--port')
    $p = if ($i -ge 0 -and $i + 1 -lt $rest.Count) { $rest[$i + 1] } elseif ($env:CSWITCH_PORT) { $env:CSWITCH_PORT } else { $DefaultPort }
    $n = 0
    if (-not [int]::TryParse([string]$p, [ref]$n) -or $n -lt 1024 -or $n -gt 65535) { throw "Invalid port '$p' (use 1024-65535)." }
    return $n
}

# ---------------------------------------------------------------- CLI

function Show-List {
    $s = Get-Status
    if ($s.liveState -eq 'unmanaged') {
        Write-Output "Claude's current login is not saved yet. Run: cswitch import <alias>"
    }
    if ($s.profiles.Count -eq 0) {
        if ($s.liveState -ne 'unmanaged') { Write-Output 'No profiles yet. Run: cswitch add <alias>' }
        return
    }
    foreach ($p in $s.profiles) {
        $marks = @()
        if ($p.active) { if ($s.running) { $marks += 'active, running' } else { $marks += 'active' } }
        if (-not $p.loggedIn) { $marks += 'not logged in' }
        $tag = if ($marks.Count) { '  [' + ($marks -join '] [') + ']' } else { '' }
        $star = if ($p.active) { '*' } else { ' ' }
        Write-Output ("{0} {1}{2}" -f $star, $p.name, $tag)
    }
}

function Show-Help {
    Write-Output @"
cswitch $Version - switch Claude Desktop accounts without logging out (unofficial)

  cswitch <alias>                 switch to a profile (restarts Claude)
  cswitch list                    list profiles (* = active)
  cswitch import <alias>          save the login Claude has now as a profile
  cswitch add <alias>             new empty profile; log in in the window that opens
  cswitch rename <old> <new>      rename a profile
  cswitch remove <alias> [-y]     delete a profile and its saved login
  cswitch ui [--port <n>]         open the web UI (http://127.0.0.1:$DefaultPort)
  cswitch ui stop                 stop the web UI server
  cswitch update                  install the latest version
  cswitch uninstall [--purge]     remove cswitch (--purge also deletes all profiles)

Profiles: $Profiles
"@
}

$cmd  = if ($args.Count) { [string]$args[0] } else { '' }
$rest = @($args | Select-Object -Skip 1 | ForEach-Object { [string]$_ })
$yes  = ($rest -contains '-y') -or ($rest -contains '--yes')
$pos  = @($rest | Where-Object { $_ -notlike '-*' })

try {
    switch ($cmd) {
        { $_ -in '', 'list', 'ls' }            { Show-List; break }
        { $_ -in 'help', '-h', '--help', '/?' } { Show-Help; break }
        { $_ -in 'version', '-v', '--version' } { Write-Output $Version; break }
        'add'    { if (-not $pos[0]) { throw 'Usage: cswitch add <alias>' }; Write-Output (Invoke-Add $pos[0]); break }
        'import' { if (-not $pos[0]) { throw 'Usage: cswitch import <alias>' }; Write-Output (Invoke-Import $pos[0]); break }
        'rename' { if ($pos.Count -lt 2) { throw 'Usage: cswitch rename <old> <new>' }; Write-Output (Invoke-Rename $pos[0] $pos[1]); break }
        { $_ -in 'remove', 'rm', 'delete' } {
            if (-not $pos[0]) { throw 'Usage: cswitch remove <alias> [-y]' }
            Assert-Exists $pos[0]
            if (-not $yes) {
                $a = Read-Host "Delete profile '$($pos[0])' and its saved login? This cannot be undone. [y/N]"
                if ($a -notmatch '^[yY]') { Write-Output 'Aborted.'; break }
            }
            Write-Output (Invoke-Remove $pos[0] $true)
            break
        }
        'ui'     {
            if ($pos[0] -eq 'stop') { Write-Output (Stop-Ui); break }
            Get-ClaudePackage | Out-Null
            Write-Output (Open-Ui (Get-UiPort $rest) ($rest -contains '--no-browser'))
            break
        }
        '__serve' { Start-UiServer ([int]$pos[0]); break }
        'update' {
            if ($env:CSWITCH_SOURCE) {
                $installer = Get-Content -LiteralPath (Join-Path $env:CSWITCH_SOURCE 'install.ps1') -Raw
            } else {
                $ref = if ($env:CSWITCH_REF) { $env:CSWITCH_REF } else { 'HEAD' }
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
                $installer = Invoke-RestMethod "$RepoRaw/$ref/install.ps1" -UseBasicParsing
            }
            Invoke-Expression $installer
            break
        }
        'uninstall' {
            $purge = $rest -contains '--purge'
            if ($purge -and -not $yes) {
                $a = Read-Host "Remove cswitch and DELETE every saved profile except the active one? [y/N]"
                if ($a -notmatch '^[yY]') { Write-Output 'Aborted.'; break }
            }
            Write-Output (Invoke-Uninstall $purge)
            break
        }
        '__postinstall' {
            Invoke-MigrateLegacy
            if ((Get-LiveState) -eq 'unmanaged') {
                Write-Host "Next: save the account Claude is logged in to now, e.g.  cswitch import work"
            }
            break
        }
        default { Write-Output (Invoke-Switch $cmd) }
    }
} catch {
    Write-Output $_.Exception.Message
    exit 1
}
