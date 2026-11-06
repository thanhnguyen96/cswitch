# End-to-end test in a throwaway sandbox. Never touches your real profiles or the Claude app:
# LOCALAPPDATA/APPDATA are redirected to a temp folder and CSWITCH_NO_APP disables start/stop.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$sb = Join-Path ([IO.Path]::GetTempPath()) ('cswitch-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$realPath = [Environment]::GetEnvironmentVariable('Path', 'User')

$env:LOCALAPPDATA = Join-Path $sb 'Local'
$env:APPDATA = Join-Path $sb 'Roaming'
$env:USERPROFILE = Join-Path $sb 'home'      # no legacy claude-use install here
$env:CSWITCH_NO_APP = '1'
$env:CSWITCH_SOURCE = $repo
$env:CSWITCH_PORT = '47899'
New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:USERPROFILE | Out-Null

$fail = 0
function Has($out, $pattern) { return [bool](@($out) -match $pattern).Count }
function Check($name, [bool]$ok) {
    if ($ok) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

$pkg = Get-AppxPackage -Name '*Claude*' | Where-Object { $_.Publisher -match 'Anthropic' } | Select-Object -First 1
if (-not $pkg) { throw 'Claude Desktop is required for this test (only its package info is read).' }
$live = Join-Path $env:LOCALAPPDATA ("Claude-Data\claude_" + $pkg.PublisherId)
New-Item -ItemType Directory -Force -Path (Join-Path $live 'claude-code') | Out-Null
Set-Content (Join-Path $live 'config.json') '{"lastKnownAccountUuid":"test-a"}'
Set-Content (Join-Path $live 'claude-code\bin.txt') 'shared payload'

try {
    Write-Host "sandbox: $sb"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') | Out-Null
    $cs = Join-Path $env:LOCALAPPDATA 'cswitch\bin\cswitch.cmd'
    $root = Join-Path $env:LOCALAPPDATA 'cswitch'
    Check 'installed' (Test-Path $cs)
    Check 'start menu shortcut' (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\cswitch.lnk'))

    Check 'list says import first' (Has (& $cs list) 'import')
    Check 'add refused before import' (Has (& $cs add b) 'import')

    & $cs import a | Out-Null
    $j = Get-Item $live -Force
    Check 'import: live is junction to a' ($j.LinkType -eq 'Junction' -and "$($j.Target)" -like '*profiles\a')
    Check 'import: claude-code moved to shared' (Test-Path (Join-Path $root 'shared\claude-code\bin.txt'))
    Check 'import: profile links shared' ((Get-Item (Join-Path $root 'profiles\a\claude-code') -Force).LinkType -eq 'Junction')

    & $cs add b | Out-Null
    Check 'add: b active' ("$((Get-Item $live -Force).Target)" -like '*profiles\b')
    Check 'add: b not logged in' (Has (& $cs list) 'b\s+\[active\] \[not logged in\]')

    & $cs a | Out-Null
    Check 'switch: a active' (Has (& $cs list) '^\* a')
    Check 'switch: unknown alias exits 1' ((Has (& $cs nope) 'No profile') -and $LASTEXITCODE -eq 1)

    & $cs rename b c | Out-Null
    Check 'rename' ((Test-Path (Join-Path $root 'profiles\c')) -and -not (Test-Path (Join-Path $root 'profiles\b')))

    & $cs remove c -y | Out-Null
    Check 'remove: profile gone' (-not (Test-Path (Join-Path $root 'profiles\c')))
    Check 'remove: shared kept' (Test-Path (Join-Path $root 'shared\claude-code\bin.txt'))

    & $cs ui --no-browser | Out-Null
    $u = "http://127.0.0.1:$env:CSWITCH_PORT"
    $page = (Invoke-WebRequest "$u/" -UseBasicParsing).Content
    $tok = [regex]::Match($page, "const token = '([0-9a-f]{32})'").Groups[1].Value
    $h = @{ 'X-Cswitch-Token' = $tok; 'Content-Type' = 'application/json' }
    Check 'ui: status' ((Invoke-RestMethod "$u/api/status" -Headers $h).active -eq 'a')
    $r = Invoke-RestMethod "$u/api/add" -Method Post -Headers $h -Body '{"name":"d"}'
    Check 'ui: add' (@($r.status.profiles | Where-Object name -eq 'd').Count -eq 1)
    $r = Invoke-RestMethod "$u/api/switch" -Method Post -Headers $h -Body '{"name":"a"}'
    Check 'ui: switch' ($r.status.active -eq 'a')
    $r = Invoke-RestMethod "$u/api/remove" -Method Post -Headers $h -Body '{"name":"d"}'
    Check 'ui: remove' (@($r.status.profiles).Count -eq 1)
    $code = try { Invoke-WebRequest "$u/api/status" -UseBasicParsing | Out-Null; 200 } catch { [int]$_.Exception.Response.StatusCode }
    Check 'ui: no token -> 403' ($code -eq 403)
    & $cs ui stop | Out-Null

    Check 'update' (Has (& $cs update) 'installed')
    Check 'update keeps profiles' (Has (& $cs list) '^\* a')

    & $cs uninstall | Out-Null
    Start-Sleep -Seconds 5    # deletion runs in a detached cmd after exit
    $li = Get-Item $live -Force
    Check 'uninstall: live is a real folder again' ($li -and -not $li.LinkType)
    Check 'uninstall: login kept' ((Get-Content (Join-Path $live 'config.json') -Raw) -match 'test-a')
    Check 'uninstall: claude-code restored' (Test-Path (Join-Path $live 'claude-code\bin.txt'))
    Check 'uninstall: cswitch folder removed' (-not (Test-Path $root))
    Check 'uninstall: shortcut removed' (-not (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\cswitch.lnk')))
} finally {
    # install/uninstall edit the real user PATH; make sure no sandbox entry is left.
    $p = [Environment]::GetEnvironmentVariable('Path', 'User')
    $clean = (@($p -split ';' | Where-Object { $_ -and $_ -notlike "$sb*" })) -join ';'
    if ($clean -ne $p) { [Environment]::SetEnvironmentVariable('Path', $clean, 'User') }
    Check 'user PATH unchanged' ([Environment]::GetEnvironmentVariable('Path', 'User') -eq $realPath)
    cmd /c rmdir /s /q "`"$sb`"" 2>$null
}

if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
