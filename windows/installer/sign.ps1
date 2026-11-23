# Authenticode signing, the one place for it. Without a certificate it does nothing, so builds
# work unsigned (and SmartScreen warns on download).
#
#   sign.ps1 file...          signs those files (Inno Setup calls it for the setup and uninstaller)
#   sign.ps1 -Folder dir      signs every .exe and .dll in dir that isn't signed yet (the app folder)
#
# The certificate comes from the WINDOWS_CERT_PFX secret (a .pfx, base64) and
# WINDOWS_CERT_PASSWORD. Most code-signing certificates now live on a hardware key or in a
# signing service (Azure Trusted Signing, SSL.com eSigner, DigiCert KeyLocker) instead of a
# .pfx; for one of those, only the signtool line below changes.
param(
    [string] $Folder,
    [Parameter(ValueFromRemainingArguments)] [string[]] $Files
)
$ErrorActionPreference = 'Stop'
if (-not $env:WINDOWS_CERT_PFX) { Write-Host 'not signed: no certificate'; exit 0 }

if ($Folder) {
    $Files = Get-ChildItem $Folder -Recurse -Include *.exe, *.dll |
        Where-Object { (Get-AuthenticodeSignature $_.FullName).Status -eq 'NotSigned' } |
        ForEach-Object FullName
}
if (-not $Files) { exit 0 }

$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
    Sort-Object FullName | Select-Object -Last 1
$pfx = Join-Path ([IO.Path]::GetTempPath()) "longyan-$PID.pfx"
[IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_CERT_PFX))
try {
    # 50 at a time, to keep the command line short.
    for ($i = 0; $i -lt $Files.Count; $i += 50) {
        $batch = $Files[$i..([Math]::Min($i + 49, $Files.Count - 1))]
        & $signtool.FullName sign /f $pfx /p $env:WINDOWS_CERT_PASSWORD /fd sha256 `
            /tr http://timestamp.digicert.com /td sha256 /d 'Longyan Reader' $batch
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    exit 0
}
finally { Remove-Item $pfx -ErrorAction SilentlyContinue }
