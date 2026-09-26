<#
Captures reference screenshots/clips of Wallpaper Engine wallpapers on the
second monitor, for comparing against Open Wallpaper Engine output.

Usage:
  .\capture-reference.ps1 -Ids 123456789,987654321
  .\capture-reference.ps1 -IdFile ids.txt       # one Workshop ID per line
Options:
  -WeRoot     Wallpaper Engine install dir (default: Steam default path)
  -Monitor    Wallpaper Engine monitor index (default 1 = second monitor)
  -Settle     Seconds to wait after switching before capture (default 8)
  -ClipSec    Clip length in seconds, 0 to skip (default 10, needs ffmpeg in PATH)
  -OutDir     Output folder (default .\reference)
#>
param(
  [string[]]$Ids,
  [string]$IdFile,
  [string]$WeRoot = "C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine",
  [int]$Monitor = 1,
  [int]$Settle = 8,
  [int]$ClipSec = 10,
  [string]$OutDir = ".\reference"
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if ($IdFile) { $Ids += Get-Content $IdFile | Where-Object { $_ -match '^\s*\d+\s*$' } | ForEach-Object { $_.Trim() } }
if (-not $Ids) { throw "No wallpaper IDs given (-Ids or -IdFile)." }

$we = Join-Path $WeRoot "wallpaper64.exe"
if (-not (Test-Path $we)) { $we = Join-Path $WeRoot "wallpaper32.exe" }
if (-not (Test-Path $we)) { throw "Wallpaper Engine not found under $WeRoot" }
$workshop = Join-Path $WeRoot "..\..\workshop\content\431960" | Resolve-Path

# Second monitor = first non-primary screen.
$screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
if (-not $screen) { throw "No second monitor detected." }
$b = $screen.Bounds
Write-Host "Capturing monitor: $($screen.DeviceName) $($b.Width)x$($b.Height) at ($($b.X),$($b.Y))"

$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ClipSec -gt 0 -and -not $ffmpeg) { Write-Warning "ffmpeg not in PATH; skipping clips."; $ClipSec = 0 }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$results = @()

foreach ($id in $Ids) {
  $dir = Join-Path $workshop $id
  $proj = Join-Path $dir "project.json"
  if (-not (Test-Path $proj)) { Write-Warning "$id not downloaded (no project.json), skipping."; continue }
  $meta = Get-Content $proj -Raw | ConvertFrom-Json
  Write-Host "[$id] $($meta.title) ($($meta.type))"

  & $we -control openWallpaper -file $proj -monitor $Monitor
  Start-Sleep -Seconds $Settle

  $idOut = Join-Path $OutDir $id
  New-Item -ItemType Directory -Force $idOut | Out-Null

  # Two stills a second apart to spot animation.
  foreach ($n in 1..2) {
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $idOut "still$n.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Start-Sleep -Seconds 1
  }

  if ($ClipSec -gt 0) {
    & ffmpeg -loglevel error -y -f gdigrab -framerate 30 -offset_x $b.X -offset_y $b.Y `
      -video_size "$($b.Width)x$($b.Height)" -t $ClipSec -i desktop `
      -c:v libx264 -pix_fmt yuv420p (Join-Path $idOut "clip.mp4")
  }

  Copy-Item $proj $idOut
  $results += [pscustomobject]@{ id = $id; title = $meta.title; type = $meta.type; file = $meta.file }
}

$results | ConvertTo-Json | Set-Content (Join-Path $OutDir "manifest.json")
Write-Host "Done. Output in $OutDir"
