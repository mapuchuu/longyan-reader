# The Store upload from the per-arch packages pack.ps1 made (x64 and arm64):
# LongyanReader_<version>_x64_arm64.msixbundle, and LongyanReader_<version>_x64_arm64.msixupload
# (a zip holding the bundle), the file Partner Center takes. Both unsigned: the Store signs.
#
#   windows/store/bundle.ps1 -Packages <folder with the .msix files> -Out <folder>
param(
    [Parameter(Mandatory)] [string] $Packages,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"

$msix = @(Get-ChildItem (Join-Path $Packages '*.msix'))
$names = $msix | ForEach-Object { $_.Name }
"packages: $($names -join ', ')" | Out-Host
$versions = @($msix | ForEach-Object { ($_.BaseName -split '_')[1] } | Sort-Object -Unique)
if ($versions.Count -ne 1) { throw "the packages have different versions: $($versions -join ', ')" }
foreach ($a in 'x64', 'arm64') { if (-not ($names -like "*_$a.msix")) { throw "no $a package in $Packages" } }
$version = $versions[0]

New-Item -ItemType Directory -Force $Out | Out-Null
$bundle = Join-Path $Out "LongyanReader_${version}_x64_arm64.msixbundle"
$makeappx = Find-SdkTool 'makeappx.exe'
& $makeappx bundle /d $Packages /p $bundle /bv $version /o | Select-Object -Last 3 | Out-Host
if ($LASTEXITCODE) { throw "makeappx bundle failed ($LASTEXITCODE)" }

$upload = Join-Path $Out "LongyanReader_${version}_x64_arm64.msixupload"
$zip = "$upload.zip"
Compress-Archive -Path $bundle -DestinationPath $zip -Force
Move-Item -Force $zip $upload
foreach ($f in $bundle, $upload) { "{0}: {1:0} MB" -f (Split-Path -Leaf $f), ((Get-Item $f).Length / 1MB) | Out-Host }
$bundle
