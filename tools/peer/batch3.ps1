# Batch 3 captures requested by the Mac audit session (items 7, 9, 10b, 11).
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$r = "C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine"
$ws = "C:\Program Files (x86)\Steam\steamapps\workshop\content\431960"
$log = Join-Path $here "batch3.log"
function Log($m) { $m | Tee-Object -FilePath $log -Append }
function Shoot { & (Join-Path $here 'shoot.ps1') @args | Out-Null }
function Pid64 { (Get-Process wallpaper64 -EA SilentlyContinue | Select -First 1).Id }
function GpuMem { $p = Pid64; $s = (Get-Counter "\GPU Process Memory(pid_$($p)_*)\Dedicated Usage" -EA SilentlyContinue).CounterSamples; [math]::Round((($s | Measure CookedValue -Sum).Sum) / 1MB, 1) }
function Gpu3D { $p = Pid64; $s = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -SampleInterval 2 -MaxSamples 3 -EA SilentlyContinue).CounterSamples | ? { $_.InstanceName -match "pid_$($p)_" }; [math]::Round((($s | Measure CookedValue -Sum).Sum) / 3, 1) }
function Cfg($k) { $c = Get-Content "$r\config.json" -Raw; if ($c -match "`"$k`"\s*:\s*(`"[^`"]*`"|\w+)") { $matches[1] } }

foreach ($id in '3606529469', '2350874185') {
  for ($i = 0; $i -lt 60 -and -not (Test-Path "$ws\$id\project.json"); $i++) { Start-Sleep 10 }
  Log "$id downloaded: $(Test-Path "$ws\$id\project.json")"
}

# 7. Texture resolution: full / half / quarter, GPU dedicated memory, lace crop.
foreach ($v in 'full', 'half', 'quarter') {
  Shoot -Id 3270035750 -Tag "texres_$v" -Set @{ resolution = $v; fps = 30 } -Clip 0 -Settle 15
  Log "7 texres=$v configAfterStart=$(Cfg resolution) dedicatedMB=$(GpuMem)"
}

# 9. Same wallpaper on 1 vs 2 monitors, FPS 15, light wallpaper (default 'retro').
$retro = "$r\projects\defaultprojects\retro\project.json"
Get-Process wallpaperui, wallpaper64 -EA 0 | Stop-Process -Force; Start-Sleep 3
$c = Get-Content "$r\config.json" -Raw; $c = $c -replace '("fps"\s*:\s*)\d+', '${1}15' -replace '("resolution"\s*:\s*)"[^"]*"', '${1}"full"'; [IO.File]::WriteAllText("$r\config.json", $c)
Start-Process "$r\wallpaper64.exe"; Start-Sleep 12
& "$r\wallpaper64.exe" -control openWallpaper -file $retro -monitor 1; Start-Sleep 10
$one = Gpu3D; $oneMem = GpuMem
& "$r\wallpaper64.exe" -control openWallpaper -file $retro -monitor 0; Start-Sleep 10
$two = Gpu3D; $twoMem = GpuMem
Log "9 retro fps15: one monitor 3D%=$one dedMB=$oneMem | two monitors 3D%=$two dedMB=$twoMem"
& "$r\wallpaper64.exe" -control openWallpaper -file "$r\projects\defaultprojects\corsair_o_tron\index.html" -monitor 0; Start-Sleep 3

# 10b. Rain on glass.
Shoot -Id 3606529469 -Set @{ fps = 30 } -Clip 5 -Settle 10
Log "10b 3606529469 captured"

# 11. 3D references at a fixed time after load, shadows high vs disabled.
foreach ($id in '3455121165', '3159348391', '3378346807', '3734636606', '3657770939', '2350874185') {
  Shoot -Id $id -Tag 'shadowsHigh_t10' -Set @{ shadows = 'high'; fps = 30 } -Clip 3 -Settle 10
  Shoot -Id $id -Tag 'shadowsOff_t10' -Set @{ shadows = 'disabled'; fps = 30 } -Clip 3 -Settle 10
  Log "11 $id captured"
}
# Puppets: 5 s clips, then centre crops for close-ups.
foreach ($id in '2515150033', '2321732083') { Shoot -Id $id -Tag 'puppet5s' -Set @{ shadows = 'medium'; fps = 30 } -Clip 5 -Settle 10; Log "11 puppet $id captured" }
Log "done"
