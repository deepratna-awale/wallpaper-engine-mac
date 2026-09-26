# Item 9 redo: 1 vs 2 monitors, same wallpaper, with playback forced to "run" everywhere so nothing pauses.
$r = "C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine"
$log = Join-Path $PSScriptRoot "batch3.log"
function Pid64 { (Get-Process wallpaper64 -EA SilentlyContinue | Select -First 1).Id }
function Gpu3D { $p = Pid64; $s = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -SampleInterval 2 -MaxSamples 5 -EA SilentlyContinue).CounterSamples | ? { $_.InstanceName -match "pid_$($p)_" }; [math]::Round((($s | Measure CookedValue -Sum).Sum) / 5, 1) }
function GpuMem { $p = Pid64; $s = (Get-Counter "\GPU Process Memory(pid_$($p)_*)\Dedicated Usage" -EA SilentlyContinue).CounterSamples; [math]::Round((($s | Measure CookedValue -Sum).Sum) / 1MB, 1) }

Get-Process wallpaperui, wallpaper64 -EA 0 | Stop-Process -Force; Start-Sleep 3
$c = Get-Content "$r\config.json" -Raw
$c = $c -replace '("fps"\s*:\s*)\d+', '${1}15'
foreach ($k in 'playbackfocus', 'playbackmaximized', 'playbackfullscreen', 'playbackaudio', 'playbackonbattery') { $c = $c -replace "(`"$k`"\s*:\s*)`"[^`"]*`"", '${1}"run"' }
[IO.File]::WriteAllText("$r\config.json", $c)
Start-Process "$r\wallpaper64.exe"; Start-Sleep 12
$retro = "$r\projects\defaultprojects\retro\project.json"
foreach ($run in 1..2) {
  & "$r\wallpaper64.exe" -control openWallpaper -file "$r\projects\defaultprojects\corsair_o_tron\index.html" -monitor 0; Start-Sleep 3
  & "$r\wallpaper64.exe" -control openWallpaper -file $retro -monitor 1; Start-Sleep 10
  $one = Gpu3D; $oneMem = GpuMem
  & "$r\wallpaper64.exe" -control openWallpaper -file $retro -monitor 0; Start-Sleep 10
  $two = Gpu3D; $twoMem = GpuMem
  "9-redo run$run retro fps15 playback=run: one monitor 3D%=$one dedMB=$oneMem | two monitors 3D%=$two dedMB=$twoMem | wallpaper64 processes=$((Get-Process wallpaper64).Count)" | Tee-Object -FilePath $log -Append
}
