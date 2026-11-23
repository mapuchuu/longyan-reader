# The installer on a clean Windows (windows-installer.yml): a silent install, the app starts
# from where it went, an upgrade over the running app (it exits and opens again), then a
# silent uninstall that leaves no app, shortcut, Settings > Apps entry or sign-in entry, and
# keeps the reader's data.
param([Parameter(Mandatory)] [string] $Setup, [string] $Logs = 'installer-logs')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Logs | Out-Null
$Logs = (Resolve-Path $Logs).Path

$app = "$env:LOCALAPPDATA\Programs\Longyan Reader"
$exe = "$app\LongyanReader.exe"
$startMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$lnk = "$startMenu\Longyan Reader.lnk"
$entry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E0CE80DD-FDC0-4DB6-97BE-2EAA3F95E820}_is1'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$appLog = "$env:LOCALAPPDATA\LongyanReader\logs\longyan.log"

function Fail([string] $why) {
    Write-Host "FAIL: $why"
    Copy-Item $appLog $Logs -ErrorAction SilentlyContinue
    exit 1
}
function Ok([string] $what) { Write-Host "ok: $what" }
function Running { @(Get-Process LongyanReader -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$app\*" }) }
function Wait([scriptblock] $done, [int] $seconds, [string] $what) {
    $until = (Get-Date).AddSeconds($seconds)
    while (-not (& $done)) {
        if ((Get-Date) -gt $until) { Fail "$what (after $seconds s)" }
        Start-Sleep -Milliseconds 500
    }
    Ok $what
}
# Waits for that process only: the setup starts the app, which keeps running.
function Run([string] $file, [string] $log) {
    $p = Start-Process $file -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$Logs\$log`"" -PassThru
    $null = $p.Handle
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $p.WaitForExit()
    $code = $p.ExitCode
    $p.Dispose()
    if ($code -ne 0) { Fail "$file exited with $code" }
    Ok ("{0} in {1:0.0} s" -f (Split-Path $file -Leaf), $clock.Elapsed.TotalSeconds)
}
function AppLog { if (Test-Path $appLog) { Get-Content $appLog -Raw } else { '' } }

if (Test-Path $app) { Fail "$app is there before the install" }
Write-Host "setup: $Setup, $([Math]::Round((Get-Item $Setup).Length / 1MB)) MB"

# 1. Install.
Run $Setup install.log
if (-not (Test-Path $exe)) { Fail "no $exe" }
if (-not (Test-Path "$app\Resources\splitter.tsv")) { Fail 'no Resources\splitter.tsv' }
if (-not (Test-Path $lnk)) { Fail "no Start menu shortcut at $lnk" }
$target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
if ($target -ne $exe) { Fail "the shortcut opens $target" }
$e = Get-ItemProperty $entry
Ok "Settings > Apps: $($e.DisplayName) $($e.DisplayVersion), $($e.Publisher)"
foreach ($pf in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
    if (Test-Path "$pf\Longyan Reader") { Fail "something in $pf" }
}
if (Get-ItemProperty $runKey -Name 'Longyan Reader' -ErrorAction SilentlyContinue) { Fail 'the install turned on open at sign-in' }
if (Running) { Fail 'a silent first install opened the app' }
Ok "installed in $app, $([Math]::Round((Get-ChildItem $app -Recurse | Measure-Object Length -Sum).Sum / 1MB)) MB"

# 2. The app starts and stays up.
Start-Process $exe
Wait { (AppLog) -match 'start ' } 60 'the app wrote its start line'
Start-Sleep 15
if (-not (Running)) { Fail "the app exited:`n$(AppLog)" }
if ((AppLog) -match "missing |couldn't start the core|crash") { Fail "the app had a problem:`n$(AppLog)" }
Ok 'the app is running'

# 3. Upgrade over the running app.
$old = (Running)[0].Id
Run $Setup upgrade.log
if (Get-Process -Id $old -ErrorAction SilentlyContinue) { Fail 'the old app is still running' }
if ((AppLog) -notmatch 'exit \(the installer asked\)') { Fail "the app didn't exit when asked:`n$(AppLog)" }
Ok 'the app exited when the installer asked'
Wait { (Running).Count -gt 0 } 30 'the upgrade opened the app again'
Start-Sleep 10
if (-not (Running)) { Fail 'the app exited after the upgrade' }

# 4. Uninstall, with open at sign-in on as the welcome window leaves it.
Set-ItemProperty $runKey -Name 'Longyan Reader' -Value "`"$exe`""
$uninstaller = ((Get-ItemProperty $entry).UninstallString).Trim('"')
Run $uninstaller uninstall.log
$until = (Get-Date).AddSeconds(60)
while ((Test-Path $app) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 500 }
if (Test-Path $app) {
    Get-ChildItem $app -Recurse -Force | ForEach-Object FullName
    Get-Process | Where-Object { $_.Path -like "$app\*" -or $_.Path -like '*_unins*' } | Format-Table Id, Path
    Fail 'the app folder is still there'
}
Ok 'the app folder is gone'
Wait { -not (Test-Path $entry) } 30 'the Settings > Apps entry is gone'
if (Running) { Fail 'the app is still running' }
if (Test-Path $lnk) { Fail 'the Start menu shortcut is still there' }
$left = Get-ChildItem $startMenu -Recurse -Filter '*Longyan*'
if ($left) { Fail "left in the Start menu: $($left.FullName)" }
foreach ($pf in $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs") {
    $left = Get-ChildItem $pf -Filter '*Longyan*' -ErrorAction SilentlyContinue
    if ($left) { Fail "left in ${pf}: $($left.FullName)" }
}
if (Get-ItemProperty $runKey -Name 'Longyan Reader' -ErrorAction SilentlyContinue) { Fail 'open at sign-in is still on' }
if (-not (Test-Path $appLog)) { Fail 'a silent uninstall deleted the reader''s data' }
Ok 'uninstalled; the reader''s data is kept'
Copy-Item $appLog $Logs -ErrorAction SilentlyContinue
