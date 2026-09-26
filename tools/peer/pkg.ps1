param([string]$Pkg, [string]$Name = "scene.json")
# Extracts one file from a Wallpaper Engine scene.pkg and prints it.
$b = [IO.File]::ReadAllBytes($Pkg); $p = 0
function I32 { $v = [BitConverter]::ToInt32($b, $script:p); $script:p += 4; $v }
function Str { $n = I32; $s = [Text.Encoding]::UTF8.GetString($b, $script:p, $n); $script:p += $n; $s }
$null = Str; $count = I32; $ents = @()
for ($i = 0; $i -lt $count; $i++) { $ents += [pscustomobject]@{ n = (Str); o = (I32); l = (I32) } }
$base = $p
$e = $ents | ? n -eq $Name | select -First 1
[Text.Encoding]::UTF8.GetString($b, $base + $e.o, $e.l)
