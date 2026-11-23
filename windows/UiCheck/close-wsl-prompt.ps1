# The windows-11-arm runner image opens "Windows Subsystem for Linux must be updated" in a
# terminal window now and then, over the desktop and with the focus, so keys and clicks the UI
# check sends go there. Started in the background before the check: closes it whenever it shows
# (nothing is accepted) and writes what started it to OUT, which the check's artifact keeps.
param([string]$Out)
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
while ($true) {
  foreach ($p in Get-Process -Name wsl, wslhost -ErrorAction SilentlyContinue) {
    $info = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
    $parent = if ($info) { Get-CimInstance Win32_Process -Filter "ProcessId=$($info.ParentProcessId)" -ErrorAction SilentlyContinue }
    "$(Get-Date -Format o) $($p.ProcessName) $($p.Id) [$($info.CommandLine)] window [$($p.MainWindowTitle)] from $($parent.Name) $($parent.ProcessId) [$($parent.CommandLine)]" | Add-Content $Out
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
  # The terminal that held it, if it stays open.
  foreach ($t in Get-Process -Name WindowsTerminal, OpenConsole -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -match 'wsl') {
    "$(Get-Date -Format o) closed $($t.ProcessName) $($t.Id) [$($t.MainWindowTitle)]" | Add-Content $Out
    Stop-Process -Id $t.Id -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 500
}
