# Headless-Chrome screenshot helper — PowerShell stand-in for screenshot.mjs
# (Node/Puppeteer are not installed on this machine).
#   powershell -File screenshot.ps1 <url> [label] [-Width 1440] [-Height 900]
# Saves to ./temporary screenshots/screenshot-N[-label].png (auto-incremented).
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Label = '',
    [int]$Width = 1440,
    [int]$Height = 900
)

$chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $chrome)) { $chrome = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" }
if (-not (Test-Path $chrome)) { throw "no Chromium browser found" }

$outDir = Join-Path $PSScriptRoot 'temporary screenshots'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$n = 1
Get-ChildItem $outDir -Filter 'screenshot-*.png' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.BaseName -match '^screenshot-(\d+)') {
        $i = [int]$Matches[1]
        if ($i -ge $n) { $n = $i + 1 }
    }
}

$name = if ([string]::IsNullOrWhiteSpace($Label)) { "screenshot-$n.png" } else { "screenshot-$n-$Label.png" }
$out = Join-Path $outDir $name

$profile = Join-Path $env:TEMP ("chrome-shot-" + [guid]::NewGuid().ToString('N'))
$args = @(
    '--headless=new'
    '--disable-gpu'
    '--hide-scrollbars'
    '--force-device-scale-factor=1'
    '--virtual-time-budget=8000'
    "--window-size=$Width,$Height"
    "--user-data-dir=$profile"
    "--screenshot=$out"
    $Url
)
& $chrome @args | Out-Null
Remove-Item $profile -Recurse -Force -ErrorAction SilentlyContinue

if (Test-Path $out) {
    Write-Host "saved $out ($Width x $Height)"
} else {
    throw "screenshot failed for $Url"
}
