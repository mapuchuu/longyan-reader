# The package's images, from the app's own art: no new drawing.
#   - Square44x44Logo.targetsize-N(_altform-unplated): the taskbar, Start's list, Settings and
#     the title bar. The frames of LongyanReader.ico itself, so the icon is the same one the
#     GitHub build shows.
#   - The tiles, the Store logo and the scaled Square44x44Logo: the mark
#     (Resources/longyan-mark.png, which the icon is made from) centred on transparent, on the
#     manifest's white BackgroundColor. The Store logo isn't put on a plate, so it gets white
#     itself, or the black mark would vanish on a dark background.
param([Parameter(Mandatory)] [string] $Out)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $Out | Out-Null

# 1. The icon's frames, which are PNGs inside the .ico: copied out as they are.
$ico = [System.IO.File]::ReadAllBytes((Resolve-Path "$PSScriptRoot/../LongyanReader/LongyanReader.ico"))
$count = [BitConverter]::ToUInt16($ico, 4)
$frames = @{}
for ($i = 0; $i -lt $count; $i++) {
    $e = 6 + 16 * $i
    $w = if ($ico[$e] -eq 0) { 256 } else { $ico[$e] }
    $size = [BitConverter]::ToInt32($ico, $e + 8)
    $offset = [BitConverter]::ToInt32($ico, $e + 12)
    $bytes = New-Object byte[] $size
    [Array]::Copy($ico, $offset, $bytes, 0, $size)
    if ($bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) { throw "the icon's ${w}px frame isn't a PNG" }
    $frames[[int]$w] = $bytes
}
foreach ($s in $frames.Keys) {
    foreach ($suffix in '', '_altform-unplated') {
        [System.IO.File]::WriteAllBytes((Join-Path $Out "Square44x44Logo.targetsize-$s$suffix.png"), $frames[$s])
    }
}

# 2. The mark, drawn at each size.
$mark = [System.Drawing.Image]::FromFile((Resolve-Path "$PSScriptRoot/../../Resources/longyan-mark.png"))
function Draw([string] $name, [int] $w, [int] $h, [double] $fraction, [bool] $white = $false) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($(if ($white) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Transparent }))
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $side = [int][Math]::Round([Math]::Min($w, $h) * $fraction)
    $g.DrawImage($mark, [int](($w - $side) / 2), [int](($h - $side) / 2), $side, $side)
    $g.Dispose()
    $bmp.Save((Join-Path $Out $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
foreach ($scale in 100, 125, 150, 200, 400) {
    $k = $scale / 100
    Draw "Square44x44Logo.scale-$scale.png" ([int](44 * $k)) ([int](44 * $k)) 0.9
    Draw "Square150x150Logo.scale-$scale.png" ([int](150 * $k)) ([int](150 * $k)) 0.5
    Draw "Wide310x150Logo.scale-$scale.png" ([int](310 * $k)) ([int](150 * $k)) 0.5
    Draw "SmallTile.scale-$scale.png" ([int](71 * $k)) ([int](71 * $k)) 0.6
    Draw "LargeTile.scale-$scale.png" ([int](310 * $k)) ([int](310 * $k)) 0.5
    Draw "StoreLogo.scale-$scale.png" ([int](50 * $k)) ([int](50 * $k)) 0.85 $true
}
$mark.Dispose()
Get-ChildItem $Out | ForEach-Object { $_.Name }
