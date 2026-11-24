# The Store package for one arch: LongyanReader_<version>_<arch>.msix, unsigned (the Store
# signs it). From an app folder that already has the Store build of the app in it
# (dotnet publish -p:Store=true, windows-msix.yml). Adds the tile and icon images, made from
# the app's icon (LongyanReader.ico) and mark (Resources/longyan-mark.png), the manifest with the
# identity from identity.txt, and resources.pri so Windows finds each image's sizes.
#
#   windows/store/pack.ps1 -App <folder with LongyanReader.exe> -Arch x64|arm64 -Out <folder>
#
# Prints the package's path.
param(
    [Parameter(Mandatory)] [string] $App,
    [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string] $Arch,
    [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"

$exe = Join-Path $App 'LongyanReader.exe'
if (-not (Test-Path $exe)) { throw "no LongyanReader.exe in ${App}" }
if (Test-Path (Join-Path $App 'WinSparkle.dll')) { throw "WinSparkle.dll is in ${App}: the Store build has no self-update" }
$version = Get-PackageVersion $exe
$id = Read-Identity

# The package's folder: the app, then the manifest, images and resources.pri.
$layout = Join-Path $Out "layout-$Arch"
if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
New-Item -ItemType Directory -Force $layout | Out-Null
Copy-Item -Recurse -Force (Join-Path $App '*') $layout

# resources.pri is made from the images and manifest alone, not the app's 2,000 files.
$pri = Join-Path $Out "pri-$Arch"
if (Test-Path $pri) { Remove-Item -Recurse -Force $pri }
New-Item -ItemType Directory -Force $pri | Out-Null
& "$PSScriptRoot/assets.ps1" -Out (Join-Path $pri 'Assets') | Out-Null

$manifest = Get-Content -Raw "$PSScriptRoot/AppxManifest.xml"
foreach ($k in @{ IdentityName = $id.IdentityName; Publisher = $id.Publisher; PublisherDisplayName = $id.PublisherDisplayName; Version = $version; Arch = $Arch }.GetEnumerator()) {
    $manifest = $manifest.Replace('$(' + $k.Key + ')', [System.Security.SecurityElement]::Escape($k.Value))
}
if ($manifest -match '\$\(') { throw 'a $(...) value was left in the manifest' }
[System.IO.File]::WriteAllText((Join-Path $pri 'AppxManifest.xml'), $manifest, (New-Object System.Text.UTF8Encoding $false))

$makepri = Find-SdkTool 'makepri.exe'
$makeappx = Find-SdkTool 'makeappx.exe'
Push-Location $pri
try {
    & $makepri createconfig /cf priconfig.xml /dq en-US /pv 10.0.0 /o | Out-Host
    if ($LASTEXITCODE) { throw "makepri createconfig failed ($LASTEXITCODE)" }
    # One resources.pri for the whole package, not split per scale (the images are small).
    $config = [xml](Get-Content -Raw priconfig.xml)
    foreach ($p in @($config.SelectNodes('//packaging'))) { [void]$p.ParentNode.RemoveChild($p) }
    $config.Save((Join-Path $PWD 'priconfig.xml'))
    & $makepri new /pr . /cf priconfig.xml /mn AppxManifest.xml /of resources.pri /o | Out-Host
    if ($LASTEXITCODE) { throw "makepri new failed ($LASTEXITCODE)" }
} finally { Pop-Location }
Copy-Item -Recurse (Join-Path $pri 'Assets') $layout
Copy-Item (Join-Path $pri 'AppxManifest.xml'), (Join-Path $pri 'resources.pri') $layout

$package = Join-Path $Out "LongyanReader_${version}_$Arch.msix"
& $makeappx pack /d $layout /p $package /o | Select-Object -Last 3 | Out-Host
if ($LASTEXITCODE) { throw "makeappx pack failed ($LASTEXITCODE)" }
"{0}: {1:0} MB, {2}, {3}" -f (Split-Path -Leaf $package), ((Get-Item $package).Length / 1MB), $version, $id.IdentityName | Out-Host
$package
