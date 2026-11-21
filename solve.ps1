<#
  Squawk challenge solver (Windows PowerShell 5.1, no dependencies).

    .\solve.ps1 -Email you@example.com           # fetch token + traffic, decode, build outputs
    .\solve.ps1 -Offline                         # reuse data\traffic.json from a previous run
    .\solve.ps1 -Offline -Check                  # also verify the decoded code with POST /check

  Outputs:
    data\traffic.json      raw radar feed
    data\radar-data.js     cleaned tracks consumed by radar.html
    letters.png            the emergency aircraft's skywriting, one panel per letter
#>
param(
  [string]$Email,
  [string]$Base = "https://squawk-challenge.airspace-intelligence.com",
  [switch]$Offline,
  [switch]$Check
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = $PSScriptRoot
$dataDir = Join-Path $root "data"
New-Item -ItemType Directory -Force $dataDir | Out-Null
$tokenFile = Join-Path $dataDir "token.txt"
$trafficFile = Join-Path $dataDir "traffic.json"

# ---------------------------------------------------------------- fetch
if (-not $Offline) {
  if (-not $Email) { throw "Pass -Email, or -Offline to reuse data\traffic.json" }
  $tok = (Invoke-RestMethod "$Base/squawk?email=$([uri]::EscapeDataString($Email))").token
  Set-Content $tokenFile $tok
  Write-Host "token: $tok"
  (Invoke-WebRequest -UseBasicParsing "$Base/traffic?token=$tok").Content | Set-Content -Encoding UTF8 $trafficFile
}
$token = (Get-Content $tokenFile -ErrorAction SilentlyContinue | Select-Object -First 1)
$raw = Get-Content $trafficFile -Raw | ConvertFrom-Json
Write-Host "reports: $($raw.Count)"

# ---------------------------------------------------------------- clean
function Get-Nm($a, $b) {
  $dy = ($b.lat - $a.lat) * 60
  $dx = ($b.lon - $a.lon) * 60 * [math]::Cos($a.lat * [math]::PI / 180)
  [math]::Sqrt($dx * $dx + $dy * $dy)
}

# Some feeds report epoch milliseconds, some seconds.
foreach ($r in $raw) { if ($r.ts -gt 1e11) { $r.ts = [long][math]::Floor($r.ts / 1000) } else { $r.ts = [long]$r.ts } }

$tracks = @{}
# Group by ICAO hex: callsigns are sometimes blank and one callsign is shared by two airframes.
foreach ($grp in ($raw | Group-Object hex)) {
  $seen = @{}
  $pts = foreach ($r in ($grp.Group | Sort-Object ts)) {
    $key = "$($r.ts)|$($r.lat)|$($r.lon)"
    if (-not $seen.ContainsKey($key)) { $seen[$key] = 1; $r }
  }
  $pts = @($pts)

  # Reject fixes that would need an impossible speed from the last accepted fix.
  $clean = New-Object System.Collections.ArrayList
  $last = $null; $rejects = 0
  foreach ($p in $pts) {
    if ($null -eq $last) { [void]$clean.Add($p); $last = $p; continue }
    $dt = [math]::Max(1, $p.ts - $last.ts)
    $limit = [math]::Max($p.gs_kt, $last.gs_kt) * 1.5 + 120
    if ((Get-Nm $last $p) / $dt * 3600 -le $limit -or $rejects -ge 4) {
      [void]$clean.Add($p); $last = $p; $rejects = 0
    } else { $rejects++ }
  }

  $names = @($pts | Where-Object { $_.callsign } | Group-Object callsign | Sort-Object Count -Descending)
  $first = $pts | Where-Object { $_.aircraft_type_icao } | Select-Object -First 1
  $tracks[$grp.Name] = [pscustomobject]@{
    hex = $grp.Name
    callsign = if ($names) { $names[0].Name } else { "" }
    type = $first.aircraft_type_icao
    from = $first.origin_airport_icao
    to = $first.destination_airport_icao
    points = $clean
    dropped = $pts.Count - $clean.Count
  }
}
$totalDropped = ($tracks.Values | Measure-Object dropped -Sum).Sum
Write-Host "aircraft: $($tracks.Count), glitch fixes dropped: $totalDropped"

# ---------------------------------------------------------------- find the emergency
# A real emergency holds 7700; dialing through it during a squawk change only shows it for seconds.
$emerg = $tracks.Values | ForEach-Object {
  $e = @($_.points | Where-Object { $_.squawk -eq "7700" -and $_.alt_ft -gt 1000 -and $_.gs_kt -gt 60 })
  if ($e.Count -gt 1) {
    [pscustomobject]@{ track = $_; seconds = $e[-1].ts - $e[0].ts; count = $e.Count }
  }
} | Sort-Object seconds -Descending | Select-Object -First 1
$em = $emerg.track
Write-Host ("emergency: {0} ({1}) squawking 7700 airborne for {2:N0} min" -f $em.callsign, $em.hex, ($emerg.seconds / 60))

# ---------------------------------------------------------------- decode the skywriting
$sky = @($em.points | Where-Object { $_.squawk -eq "7700" })

# Altitude flips between two bands ~1300 ft apart: low band = pen down, high band = repositioning.
$segs = New-Object System.Collections.ArrayList
$start = 0
for ($i = 1; $i -le $sky.Count; $i++) {
  if ($i -eq $sky.Count -or [math]::Abs($sky[$i].alt_ft - $sky[$i - 1].alt_ft) -gt 700) {
    $alts = @($sky[$start..($i - 1)] | ForEach-Object { $_.alt_ft } | Sort-Object)
    [void]$segs.Add([pscustomobject]@{ from = $start; to = $i - 1; alt = $alts[[int]($alts.Count / 2)]; pen = $false; letter = -1 })
    $start = $i
  }
}
for ($k = 0; $k -lt $segs.Count; $k++) {
  $nb = @()
  if ($k -gt 0) { $nb += $segs[$k - 1].alt }
  if ($k -lt $segs.Count - 1) { $nb += $segs[$k + 1].alt }
  $segs[$k].pen = $segs[$k].alt -lt ($nb | Measure-Object -Average).Average
}

# Short pen-up hops stay inside a letter (e.g. the bar of an F or E); long loops move to the next one.
$letter = -1; $prevEnd = $null
foreach ($s in $segs) {
  if (-not $s.pen) { continue }
  if ($null -eq $prevEnd -or ($sky[$s.from].ts - $prevEnd) -gt 300) { $letter++ }
  $s.letter = $letter
  $prevEnd = $sky[$s.to].ts
}
$letterCount = $letter + 1
$penOf = @{}; $letterOf = @{}
foreach ($s in $segs) {
  for ($i = $s.from; $i -le $s.to; $i++) {
    $penOf[$sky[$i].ts] = $s.pen
    $letterOf[$sky[$i].ts] = $s.letter
  }
}
Write-Host "segments: $($segs.Count), letters: $letterCount"

# The letters are drawn on a grid rotated off north; recover it from the pen-down headings.
$sx = 0; $sy = 0
foreach ($p in $sky) {
  if ($penOf[$p.ts] -and $p.gs_kt -gt 180) {
    $a = 4 * $p.track_deg * [math]::PI / 180
    $sx += [math]::Cos($a); $sy += [math]::Sin($a)
  }
}
$gridDeg = ([math]::Atan2($sy, $sx) * 180 / [math]::PI / 4 + 360) % 90
$rot = (90 - $gridDeg) % 90
if ($rot -gt 45) { $rot -= 90 }
Write-Host ("grid rotation: {0:N1} deg" -f $rot)

$lat0 = ($sky | Measure-Object lat -Average).Average
$lon0 = ($sky | Measure-Object lon -Average).Average
$th = $rot * [math]::PI / 180
function Get-Local($p) {
  $x = ($p.lon - $lon0) * 60 * [math]::Cos($lat0 * [math]::PI / 180)
  $y = ($p.lat - $lat0) * 60
  , @(($x * [math]::Cos($th) + $y * [math]::Sin($th)), (-$x * [math]::Sin($th) + $y * [math]::Cos($th)))
}

# ---------------------------------------------------------------- letters.png
$cell = 260; $pad = 40
$bmp = New-Object Drawing.Bitmap ($cell * $letterCount), ($cell + 40)
$gr = [Drawing.Graphics]::FromImage($bmp)
$gr.SmoothingMode = 'AntiAlias'
$gr.Clear([Drawing.Color]::FromArgb(9, 11, 12))
$ink = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(204, 255, 0)), 6
$ink.StartCap = 'Round'; $ink.EndCap = 'Round'; $ink.LineJoin = 'Round'
$hop = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(87, 95, 109)), 2
$hop.DashStyle = 'Dash'
$font = New-Object Drawing.Font "Consolas", 11
$all = foreach ($p in $sky) { if ($letterOf[$p.ts] -ge 0) { Get-Local $p } }
$span = [math]::Max((($all | ForEach-Object { $_[0] } | Measure-Object -Max -Min) | ForEach-Object { $_.Maximum - $_.Minimum }),
                    (($all | ForEach-Object { $_[1] } | Measure-Object -Max -Min) | ForEach-Object { $_.Maximum - $_.Minimum }))
$scale = ($cell - 2 * $pad) / $span
for ($L = 0; $L -lt $letterCount; $L++) {
  $mine = @($segs | Where-Object { $_.letter -eq $L })
  $lo = $mine[0].from; $hi = $mine[-1].to
  $xy = @($sky[$lo..$hi] | ForEach-Object { , (Get-Local $_) })
  $cx = (($xy | ForEach-Object { $_[0] } | Measure-Object -Max -Min) | ForEach-Object { ($_.Maximum + $_.Minimum) / 2 })
  $cy = (($xy | ForEach-Object { $_[1] } | Measure-Object -Max -Min) | ForEach-Object { ($_.Maximum + $_.Minimum) / 2 })
  $ox = $L * $cell + $cell / 2; $oy = $cell / 2 + 10
  for ($i = $lo + 1; $i -le $hi; $i++) {
    $a = $xy[$i - 1 - $lo]; $b = $xy[$i - $lo]
    $pen = if ($penOf[$sky[$i].ts] -and $penOf[$sky[$i - 1].ts]) { $ink } else { $hop }
    $gr.DrawLine($pen, [float]($ox + ($a[0] - $cx) * $scale), [float]($oy - ($a[1] - $cy) * $scale),
                       [float]($ox + ($b[0] - $cx) * $scale), [float]($oy - ($b[1] - $cy) * $scale))
  }
  $when = [DateTimeOffset]::FromUnixTimeSeconds($sky[$lo].ts).UtcDateTime.ToString("HH:mm")
  $gr.DrawString("letter $($L + 1)  $($when)Z", $font, [Drawing.Brushes]::Gray, $L * $cell + 10, $cell + 12)
}
$bmp.Save((Join-Path $root "letters.png"))
Write-Host "wrote letters.png  (read the panels left to right)"

# ---------------------------------------------------------------- radar-data.js
$t0 = ($raw | Measure-Object ts -Minimum).Minimum
$inv = [Globalization.CultureInfo]::InvariantCulture
$sb = New-Object Text.StringBuilder
[void]$sb.Append("window.SQUAWK = {t0:$t0,emergency:'$($em.hex)',rotation:$($rot.ToString('0.00', $inv)),letters:$letterCount,")
[void]$sb.Append("center:[$($lat0.ToString('0.0000', $inv)),$($lon0.ToString('0.0000', $inv))],aircraft:[`n")
foreach ($t in ($tracks.Values | Sort-Object hex)) {
  $isEm = $t.hex -eq $em.hex
  [void]$sb.Append("{hex:'$($t.hex)',cs:'$($t.callsign)',type:'$($t.type)',from:'$($t.from)',to:'$($t.to)',p:[")
  $parts = foreach ($p in $t.points) {
    $f = "[{0},{1},{2},{3},'{4}',{5}" -f ($p.ts - $t0), $p.lat.ToString('0.0000', $inv), $p.lon.ToString('0.0000', $inv), $p.alt_ft, $p.squawk, $p.gs_kt
    if ($isEm -and $letterOf.ContainsKey($p.ts)) { $f += ",$([int]$penOf[$p.ts]),$($letterOf[$p.ts])" }
    "$f]"
  }
  [void]$sb.Append(($parts -join ","))
  [void]$sb.Append("]},`n")
}
[void]$sb.Append("]};`n")
[IO.File]::WriteAllText((Join-Path $dataDir "radar-data.js"), $sb.ToString(), (New-Object Text.UTF8Encoding $false))
Write-Host "wrote data\radar-data.js  (open radar.html)"

# ---------------------------------------------------------------- verify
if ($Check) {
  $guess = Read-Host "Access code as read from letters.png"
  $res = Invoke-RestMethod -Method Post "$Base/check" -ContentType "application/json" -Body (@{ token = $token; guess = $guess } | ConvertTo-Json)
  Write-Host "check '$guess': correct = $($res.correct)"
}
