# Installs a Store package on a CI runner the way a sideload would, checks the app, and
# uninstalls it. Never for a real PC: it makes a throwaway certificate for identity.txt's
# Publisher, trusts it machine-wide (admin) and signs a copy of the package with it. The Store
# signs the real upload itself.
#
#   powershell -File windows/store/test.ps1 -Package <.msix or .msixbundle> [-UiCheck <UiCheck.exe>] -Out <folder>
#
# With -UiCheck: UiCheck --packaged (windows/UiCheck/PackagedCheck.cs) runs against the
# installed app. Then the uninstall must leave nothing: the package's data folder (settings,
# history, the model, logs), its registry hive and startup task, and nothing in the real
# %LOCALAPPDATA%\LongyanReader or HKCU\Software\LongyanReader.
#
# Windows PowerShell, not pwsh: the Appx cmdlets.
param(
    [Parameter(Mandatory)] [string] $Package,
    [string] $UiCheck = '',
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$id = Read-Identity
New-Item -ItemType Directory -Force $Out | Out-Null
$failures = New-Object System.Collections.Generic.List[string]

# A certificate for the Publisher name, for code signing, gone in two days.
$cert = New-SelfSignedCertificate -Type Custom -Subject $id.Publisher -KeyUsage DigitalSignature `
    -FriendlyName 'Longyan Reader CI test package' -CertStoreLocation Cert:\CurrentUser\My `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') -NotAfter (Get-Date).AddDays(2)
$cer = Join-Path $Out 'test.cer'
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null

$signed = Join-Path $Out ('signed-' + (Split-Path -Leaf $Package))
Copy-Item -Force $Package $signed
$signtool = Find-SdkTool 'signtool.exe'
& $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /s My $signed | Out-Host
if ($LASTEXITCODE) { throw "signtool failed ($LASTEXITCODE)" }

Add-AppxPackage -Path $signed
$pkg = Get-AppxPackage -Name $id.IdentityName
if (-not $pkg) { throw "$($id.IdentityName) isn't installed after Add-AppxPackage" }
"installed {0} ({1}) at {2}" -f $pkg.PackageFullName, $pkg.Architecture, $pkg.InstallLocation | Out-Host
$family = $pkg.PackageFamilyName
if ($id.PackageFamilyName -and $family -ne $id.PackageFamilyName) { $failures.Add("the package family is $family, not Partner Center's $($id.PackageFamilyName)") }
$cpu = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'Arm64' } else { 'X64' }
if ("$($pkg.Architecture)" -ne $cpu) { $failures.Add("installed the $($pkg.Architecture) package on a $cpu PC") }
foreach ($f in 'LongyanReader.exe', 'LongyanBridge.dll', 'llama.dll', 'Resources', 'resources.pri', 'Assets\StoreLogo.scale-100.png') {
    if (-not (Test-Path (Join-Path $pkg.InstallLocation $f))) { $failures.Add("the installed package has no $f") }
}
if (Test-Path (Join-Path $pkg.InstallLocation 'WinSparkle.dll')) { $failures.Add('the installed package has WinSparkle.dll') }
$manifest = [xml](Get-Content -Raw (Join-Path $pkg.InstallLocation 'AppxManifest.xml'))
$caps = @($manifest.Package.Capabilities.ChildNodes | ForEach-Object { $_.Name })
"capabilities: $($caps -join ', ')" | Out-Host
if ($caps.Count -ne 1 -or $caps[0] -ne 'runFullTrust') { $failures.Add("capabilities are $($caps -join ', '), not just runFullTrust") }

if ($UiCheck) {
    & $UiCheck --packaged $family (Join-Path $Out 'packaged')
    if ($LASTEXITCODE) { $failures.Add("UiCheck --packaged failed ($LASTEXITCODE)") }
}
Get-Process LongyanReader -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2

# Uninstall: everything the app kept goes with it.
$data = Join-Path $env:LOCALAPPDATA "Packages\$family"
$tasks = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\$family"
if ($UiCheck) {
    $kept = Join-Path $data 'LocalCache\Local\LongyanReader'
    if (Test-Path $kept) { "the package's data before uninstall:" | Out-Host; Get-ChildItem -Recurse $kept | ForEach-Object { '  ' + $_.FullName.Substring($kept.Length) } | Out-Host }
    else { $failures.Add("no data in $kept before uninstall") }
}
Remove-AppxPackage -Package $pkg.PackageFullName
$gone = $false
for ($i = 0; $i -lt 30 -and -not $gone; $i++) { $gone = -not (Test-Path $data); if (-not $gone) { Start-Sleep 1 } }
if (-not $gone) { $failures.Add("$data is still there after uninstall"); Get-ChildItem -Recurse $data | Select-Object -First 20 | Out-Host }
if (Test-Path $tasks) { $failures.Add("the startup task's registry key is still there after uninstall") }
if (Get-AppxPackage -Name $id.IdentityName) { $failures.Add('the package is still installed') }
if (Test-Path (Join-Path $env:LOCALAPPDATA 'LongyanReader')) { $failures.Add('the real %LOCALAPPDATA%\LongyanReader exists') }
if (Test-Path 'HKCU:\Software\LongyanReader') { $failures.Add('the real HKCU\Software\LongyanReader exists') }
$run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
if ($run -and $run.PSObject.Properties['Longyan Reader']) { $failures.Add('the Run key has a Longyan Reader value') }

Remove-Item "Cert:\LocalMachine\TrustedPeople\$($cert.Thumbprint)", "Cert:\CurrentUser\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
Remove-Item -Force $signed
foreach ($f in $failures) { "FAILED: $f" | Out-Host }
if ($failures.Count) { exit 1 }
'installed, checked and uninstalled cleanly' | Out-Host
