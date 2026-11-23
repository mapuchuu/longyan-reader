# The installer's pictures, from the app's mark (Resources/longyan-mark.png): the small one at
# the top right of each page and the tall one on the last page, at the sizes Inno Setup picks
# from for 100% to 200% scaling. Writes them into the given folder and returns the two
# comma-separated lists for /DSmallImage= and /DLargeImage= (Small, Large).
param([Parameter(Mandatory)] [string] $Out)
Add-Type -AssemblyName System.Drawing
$mark = [System.Drawing.Image]::FromFile((Resolve-Path "$PSScriptRoot/../../Resources/longyan-mark.png"))
New-Item -ItemType Directory -Force $Out | Out-Null

function Draw([int] $w, [int] $h, [double] $fraction, [string] $file) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $side = [int]([Math]::Min($w, $h) * $fraction)
    $g.DrawImage($mark, [int](($w - $side) / 2), [int](($h - $side) / 2), $side, $side)
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $bmp.Dispose()
    return $file
}

$small = foreach ($s in 55, 69, 83, 110) { Draw $s $s 0.9 (Join-Path $Out "small-$s.bmp") }
$large = foreach ($k in 1.0, 1.25, 1.5, 2.0) {
    $w = [int](164 * $k); $h = [int](314 * $k)
    Draw $w $h 0.6 (Join-Path $Out "large-$w.bmp")
}
@{ Small = $small -join ','; Large = $large -join ',' }
