# Slice a tall full-page screenshot into readable chunks for review.
#   & slice.ps1 -Source "temporary screenshots\screenshot-N-full.png" -Height 1100
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [int]$Height = 1100,
    [string]$Prefix = 'slice'
)

Add-Type -AssemblyName System.Drawing

if (-not [System.IO.Path]::IsPathRooted($Source)) { $Source = Join-Path $PSScriptRoot $Source }
$bmp = [System.Drawing.Bitmap]::FromFile($Source)
$w = $bmp.Width

# Find the last row that is not the flat page background, so empty tail is dropped.
$bg = $bmp.GetPixel(4, $bmp.Height - 4)
$last = 0
for ($y = $bmp.Height - 1; $y -ge 0; $y--) {
    $hit = $false
    for ($x = 0; $x -lt $w; $x += 17) {
        $p = $bmp.GetPixel($x, $y)
        if ([math]::Abs($p.R - $bg.R) -gt 6 -or [math]::Abs($p.G - $bg.G) -gt 6 -or [math]::Abs($p.B - $bg.B) -gt 6) { $hit = $true; break }
    }
    if ($hit) { $last = $y; break }
}
$contentHeight = $last + 1
Write-Output "content height: $contentHeight px (canvas $($bmp.Height))"

$outDir = Join-Path $PSScriptRoot 'temporary screenshots'
$i = 0
for ($y = 0; $y -lt $contentHeight; $y += $Height) {
    $h = [math]::Min($Height, $contentHeight - $y)
    $r = New-Object System.Drawing.Rectangle(0, $y, $w, $h)
    $part = $bmp.Clone($r, $bmp.PixelFormat)
    $path = Join-Path $outDir ("{0}-{1:d2}.png" -f $Prefix, $i)
    $part.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $part.Dispose()
    Write-Output ("{0}  y={1}..{2}" -f (Split-Path $path -Leaf), $y, ($y + $h))
    $i++
}
$bmp.Dispose()
