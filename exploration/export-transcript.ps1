param([string]$In, [string]$Out)
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine("# Squawk challenge - AI session transcript (Cursor agent)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("User messages, assistant replies, and every tool call the agent made, in order. Tool outputs are not stored in the log.")
[void]$sb.AppendLine("")
foreach ($line in Get-Content $In -Encoding UTF8) {
  if (-not $line.Trim()) { continue }
  $m = $line | ConvertFrom-Json
  foreach ($c in $m.message.content) {
    if ($c.type -eq "text") {
      $text = $c.text -replace '(?s)<timestamp>.*?</timestamp>', '' -replace '</?user_query>', '' -replace '(?s)<system_reminder>.*?</system_reminder>', ''
      $text = $text.Trim()
      if (-not $text) { continue }
      if ($m.role -eq "user") { [void]$sb.AppendLine("## User`n`n$text`n") }
      else { [void]$sb.AppendLine("**Assistant:** $text`n") }
    } elseif ($c.type -eq "tool_use") {
      $inp = $c.input
      $body = if ($inp.command) { $inp.command }
              elseif ($inp.contents) { "(wrote $($inp.path))" }
              elseif ($inp.arguments) { ($inp.arguments | ConvertTo-Json -Depth 5 -Compress) }
              else { ($inp | ConvertTo-Json -Depth 5 -Compress) }
      $label = if ($c.name -eq "CallDynamicTool") { "$($inp.namespace)/$($inp.toolName)" } else { $c.name }
      if ($c.name -in "Write", "StrReplace", "Read") { $body = "$($inp.path)" }
      [void]$sb.AppendLine("<details><summary>tool: $label</summary>`n`n``````text`n$body`n```````n</details>`n")
    }
  }
}
[IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
