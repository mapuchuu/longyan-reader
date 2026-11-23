# The installer on a clean Windows (windows-installer.yml): a silent install, the app starts
# from where it went, an upgrade over the running app (it exits and opens again), an update as
# WinSparkle runs it (/OPEN=1, with the app already closed: it opens again), then a silent
# uninstall that leaves no app, shortcut, Settings > Apps entry, open at login entry or app
# data, and leaves other folders and keys alone.
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
$data = "$env:LOCALAPPDATA\LongyanReader"
$appLog = "$data\logs\longyan.log"
$dataKey = 'HKCU:\Software\LongyanReader'
# The flags an update runs the installer with (scripts/windows-feed.py UPDATE_ARGS).
$updateArgs = '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/OPEN=1'

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
function Run([string] $file, [string] $log, [string[]] $flags = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')) {
    $p = Start-Process $file -ArgumentList ($flags + "/LOG=`"$Logs\$log`"") -PassThru
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
if (-not (Test-Path "$app\WinSparkle.dll")) { Fail 'no WinSparkle.dll, so no updates' }
if (-not (Test-Path $lnk)) { Fail "no Start menu shortcut at $lnk" }
$target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
if ($target -ne $exe) { Fail "the shortcut opens $target" }
$e = Get-ItemProperty $entry
Ok "Settings > Apps: $($e.DisplayName) $($e.DisplayVersion), $($e.Publisher)"
foreach ($pf in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
    if (Test-Path "$pf\Longyan Reader") { Fail "something in $pf" }
}
if (Get-ItemProperty $runKey -Name 'Longyan Reader' -ErrorAction SilentlyContinue) { Fail 'the install turned on open at login' }
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

# 4. An update as WinSparkle runs it: the app exits for the update, then the installer runs
# with the update flags and opens it again.
$ev = [Threading.EventWaitHandle]::OpenExisting('LongyanReader.Windows.Quit')
$null = $ev.Set()
$ev.Dispose()
Wait { (Running).Count -eq 0 } 30 'the app exited for the update'
Run $Setup update.log $updateArgs
Wait { (Running).Count -gt 0 } 30 'the update opened the app again (/OPEN=1)'
Start-Sleep 10
if (-not (Running)) { Fail 'the app exited after the update' }

# 5. Uninstall, with open at login on as the welcome window leaves it, and the reader's data:
# settings, history, a model, logs and the updater's settings. Next to them, a folder and a key
# with a longer name that must stay.
Set-ItemProperty $runKey -Name 'Longyan Reader' -Value "`"$exe`""
New-Item -ItemType Directory -Force "$data\models", "$data\History" | Out-Null
Set-Content "$data\models\qwen3.5-4b-q4_k_m.gguf" 'not a model'
Set-Content "$data\History\lookups.jsonl" '{}'
if (-not (Test-Path "$data\settings.json")) { Set-Content "$data\settings.json" '{}' }
$null = New-Item -Force "$dataKey\Updates"
Set-ItemProperty "$dataKey\Updates" -Name CheckForUpdates -Value '1'
$neighbour = "$env:LOCALAPPDATA\LongyanReaderKeep"
$neighbourKey = 'HKCU:\Software\LongyanReaderKeep'
New-Item -ItemType Directory -Force $neighbour | Out-Null
Set-Content "$neighbour\keep.txt" 'keep'
$null = New-Item -Force $neighbourKey
Copy-Item $appLog $Logs -ErrorAction SilentlyContinue
$uninstaller = ((Get-ItemProperty $entry).UninstallString).Trim('"')
Run $uninstaller uninstall.log
$until = (Get-Date).AddSeconds(60)
while ((Test-Path $app) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 500 }
if (Test-Path $app) {
    Get-ChildItem $app -Recurse -Force | ForEach-Object FullName
    Get-Process | Where-Object { $_.Path -like "$app\*" -or $_.Path -like '*_unins*' } | Format-Table Id, Path
    Remove-Item $app -ErrorAction Continue
    Fail "the app folder is still there (deleting it now: $(if (Test-Path $app) { 'failed' } else { 'worked' }))"
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
if (Get-ItemProperty $runKey -Name 'Longyan Reader' -ErrorAction SilentlyContinue) { Fail 'open at login is still on' }
Wait { -not (Test-Path $data) } 30 "the app's data is gone ($data)"
if (Test-Path $dataKey) { Fail "$dataKey is still there" }
Ok "$dataKey is gone"
if (-not (Test-Path "$neighbour\keep.txt")) { Fail "the uninstall deleted $neighbour" }
if (-not (Test-Path $neighbourKey)) { Fail "the uninstall deleted $neighbourKey" }
Ok 'other folders and keys are kept'
Remove-Item -Recurse -Force $neighbour, $neighbourKey
Ok 'uninstalled, with the app''s data'
