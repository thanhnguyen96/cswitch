# cswitch installer.
#   irm https://raw.githubusercontent.com/thanhnguyen96/cswitch/HEAD/install.ps1 | iex
# Options (environment variables):
#   CSWITCH_REF     git ref to install (tag, branch or commit). Default: HEAD
#   CSWITCH_SOURCE  install from a local folder instead of GitHub (for development)
# Installs per user into %LOCALAPPDATA%\cswitch. No admin rights needed.
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

& {
    $ErrorActionPreference = 'Stop'
    $repoRaw = 'https://raw.githubusercontent.com/thanhnguyen96/cswitch'
    $ref     = if ($env:CSWITCH_REF) { $env:CSWITCH_REF } else { 'HEAD' }
    $root    = Join-Path $env:LOCALAPPDATA 'cswitch'
    $app     = Join-Path $root 'app'
    $bin     = Join-Path $root 'bin'
    $files   = @('cswitch.ps1', 'ui.html')

    if ($env:OS -ne 'Windows_NT') { throw 'cswitch only runs on Windows.' }
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Where-Object { $_.Publisher -match 'Anthropic' }
    if (-not $pkg) { Write-Warning 'Claude Desktop (Microsoft Store build) was not found for this user. cswitch needs it to do anything.' }

    # Download to a temp folder first so a failed download never leaves a broken install.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cswitch-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        if ($env:CSWITCH_SOURCE) {
            Write-Host "Installing cswitch from $env:CSWITCH_SOURCE ..."
            foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $env:CSWITCH_SOURCE $f) -Destination (Join-Path $tmp $f) }
        } else {
            Write-Host "Installing cswitch ($ref) ..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
            foreach ($f in $files) {
                Invoke-WebRequest -Uri "$repoRaw/$ref/$f" -OutFile (Join-Path $tmp $f) -UseBasicParsing
            }
        }
        New-Item -ItemType Directory -Force -Path $app, $bin | Out-Null
        foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $tmp $f) -Destination (Join-Path $app $f) -Force }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $shim = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\app\cswitch.ps1`" %*`r`n"
    [IO.File]::WriteAllText((Join-Path $bin 'cswitch.cmd'), $shim, [Text.Encoding]::ASCII)

    # Add bin to the user PATH (and to this session).
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ })
    if (-not ($parts | Where-Object { $_.TrimEnd('\') -ieq $bin })) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $bin) -join ';'), 'User')
        Write-Host "Added $bin to your PATH."
    }
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $bin })) { $env:Path = "$env:Path;$bin" }

    # Start menu entry that opens the web UI.
    $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\cswitch.lnk'
    New-Item -ItemType Directory -Force -Path (Split-Path $lnk) | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = 'powershell.exe'
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app\cswitch.ps1`" ui"
    $s.Description = 'Switch Claude Desktop accounts'
    $s.WindowStyle = 7
    $s.Save()

    $main = Join-Path $app 'cswitch.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $main __postinstall
    $v = & powershell -NoProfile -ExecutionPolicy Bypass -File $main version
    $port = if ($env:CSWITCH_PORT) { $env:CSWITCH_PORT } else { '47821' }

    Write-Host ''
    Write-Host "cswitch $v installed." -ForegroundColor Green
    Write-Host ''
    Write-Host '  Web UI'
    Write-Host "    cswitch ui              then open http://127.0.0.1:$port"
    Write-Host "    or Start menu > cswitch"
    Write-Host ''
    Write-Host '  Terminal'
    Write-Host '    cswitch list            show profiles'
    Write-Host '    cswitch import <alias>  save the account Claude is logged in to now'
    Write-Host '    cswitch add <alias>     add another account (log in once)'
    Write-Host '    cswitch <alias>         switch account'
    Write-Host '    cswitch help            all commands'
    Write-Host ''
    Write-Host '  Open a new terminal first so PATH picks up cswitch.'
}
