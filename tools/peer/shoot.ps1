param([string]$Id, [string]$Tag = "default", [hashtable]$Set = @{}, [int]$Clip = 5, [int]$Settle = 10, [switch]$Mouse)
# Applies config overrides (restarting WE if any), opens $Id on monitor 1 (second screen), captures stills + clip.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$r = "C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine"
$ws = "C:\Program Files (x86)\Steam\steamapps\workshop\content\431960"
$out = Join-Path $PSScriptRoot "$Id\$Tag"; New-Item -ItemType Directory -Force $out | Out-Null
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

if ($Set.Count) {
  Get-Process wallpaperui, wallpaper64 -EA SilentlyContinue | Stop-Process -Force
  Start-Sleep 3
  $c = Get-Content "$r\config.json" -Raw
  foreach ($k in $Set.Keys) {
    $v = $Set[$k]; $lit = if ($v -is [bool]) { "$v".ToLower() } elseif ($v -is [int]) { "$v" } else { "`"$v`"" }
    $c = [regex]::Replace($c, "(`"$k`"\s*:\s*)(`"[^`"]*`"|true|false|\d+)", "`${1}$lit")
  }
  [IO.File]::WriteAllText("$r\config.json", $c)
  Start-Process "$r\wallpaper64.exe"
  Start-Sleep 12
}

& "$r\wallpaper64.exe" -control openWallpaper -file "$ws\$Id\project.json" -monitor 1
Start-Sleep $Settle

$b = ([System.Windows.Forms.Screen]::AllScreens | ? { -not $_.Primary })[0].Bounds
function Snap($name) {
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
  $bmp.Save((Join-Path $out "$name.png")); $g.Dispose(); $bmp.Dispose()
}
if ($Mouse) {
  $cy = $b.Y + $b.Height / 2
  foreach ($p in @(@('left', 0), @('center', 0.5), @('right', 1))) {
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point ([int]($b.X + $p[1] * ($b.Width - 1))), ([int]$cy)
    Start-Sleep 3; Snap "mouse_$($p[0])"
  }
} else {
  Snap still1; Start-Sleep 2; Snap still2
}
if ($Clip -gt 0) {
  & ffmpeg -loglevel error -y -f gdigrab -framerate 30 -offset_x $b.X -offset_y $b.Y -video_size "$($b.Width)x$($b.Height)" -t $Clip -i desktop -c:v libx264 -pix_fmt yuv420p (Join-Path $out "clip.mp4")
}
"$Id/$Tag done"
