param([string]$hex = "ab4889", [int]$slices = 12, [string]$out = "slices.png", [string]$sq = "7700")
Add-Type -AssemblyName System.Drawing
$d = Get-Content "$PSScriptRoot\norm.json" -Raw | ConvertFrom-Json
$g = @($d | Where-Object { $_.hex -eq $hex -and ($sq -eq "" -or $_.squawk -eq $sq) } | Sort-Object ts)

function Dist($a, $b) {
  $dy = ($a.lat - $b.lat) * 60
  $dx = ($a.lon - $b.lon) * 60 * [math]::Cos($a.lat * [math]::PI / 180)
  [math]::Sqrt($dx * $dx + $dy * $dy)
}

# drop points that are far from both neighbours relative to the time gap
$clean = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $g.Count; $i++) {
  $p = $g[$i]
  $ok = $true
  if ($i -gt 0 -and $i -lt $g.Count - 1) {
    $a = $g[$i - 1]; $b = $g[$i + 1]
    $ta = [math]::Max(1, $p.ts - $a.ts); $tb = [math]::Max(1, $b.ts - $p.ts)
    if ((Dist $a $p) / $ta * 3600 -gt 400 -or (Dist $p $b) / $tb * 3600 -gt 400) { $ok = $false }
  }
  if ($ok) { [void]$clean.Add($p) }
}
"kept $($clean.Count) of $($g.Count)"

$minLa = ($clean.lat | Measure-Object -Minimum).Minimum; $maxLa = ($clean.lat | Measure-Object -Maximum).Maximum
$minLo = ($clean.lon | Measure-Object -Minimum).Minimum; $maxLo = ($clean.lon | Measure-Object -Maximum).Maximum
$cell = 380; $cols = [math]::Min($slices, 5); $rows = [math]::Ceiling($slices / $cols)
$bmp = New-Object Drawing.Bitmap ($cell * $cols), ($cell * $rows)
$gr = [Drawing.Graphics]::FromImage($bmp); $gr.Clear([Drawing.Color]::White); $gr.SmoothingMode = 'AntiAlias'
$s = [math]::Min(($cell - 30) / ($maxLo - $minLo), ($cell - 30) / ($maxLa - $minLa))
$font = New-Object Drawing.Font "Arial", 9
$bounds = @(0); for ($i = 1; $i -lt $clean.Count; $i++) { if ([math]::Abs($clean[$i].alt_ft - $clean[$i-1].alt_ft) -gt 700) { $bounds += $i } }; $bounds += $clean.Count; "bounds: $($bounds -join ",")"
for ($k = 0; $k -lt $slices; $k++) {
  $ox = ($k % $cols) * $cell; $oy = [math]::Floor($k / $cols) * $cell
  $gr.DrawRectangle([Drawing.Pens]::LightGray, $ox, $oy, $cell - 1, $cell - 1)
  if ($k -ge $bounds.Count - 1) { break }; $start = $bounds[$k]; $end = $bounds[$k+1] - 1
  
  $gr.DrawString("$k  alt=$($clean[$start].alt_ft) n=$($end-$start+1)", $font, [Drawing.Brushes]::Black, $ox + 3, $oy + 3)
  for ($i = $start + 1; $i -le $end; $i++) {
    $a = $clean[$i - 1]; $b = $clean[$i]
    $f = ($i - $start) / [math]::Max(1, $end - $start)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb([int](255 * $f), 0, [int](255 * (1 - $f)))), 2
    $gr.DrawLine($pen, [float]($ox + 15 + ($a.lon - $minLo) * $s), [float]($oy + 15 + ($maxLa - $a.lat) * $s),
                       [float]($ox + 15 + ($b.lon - $minLo) * $s), [float]($oy + 15 + ($maxLa - $b.lat) * $s))
  }
}
for ($k = 0; $k -lt $bounds.Count - 1; $k++) { $ox = ($k % $cols) * $cell; $oy = [math]::Floor($k / $cols) * $cell; $q = $clean[$bounds[$k]]; $gr.FillEllipse([Drawing.Brushes]::LimeGreen, [float]($ox + 15 + ($q.lon - $minLo) * $s - 5), [float]($oy + 15 + ($maxLa - $q.lat) * $s - 5), 10, 10) }; $bmp.Save("$PSScriptRoot\$out")
