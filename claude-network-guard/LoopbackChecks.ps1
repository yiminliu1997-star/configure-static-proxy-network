function Get-LoopbackChecks {
 $dir=Join-Path $PSScriptRoot 'LoopbackGuard'
 $coverage=$false;$rules=$false;$detail=''
 try {
  $expected=@((Read-Json (Join-Path $Config.RuntimeRoot 'EgressGuard\targets.json')).Targets | Where-Object {$_.Label -notmatch 'Microsoft Edge|Google Chrome'} | ForEach-Object {
   $ports=if($_.Label -like '*Router*'){'12460'}elseif($_.Label -like 'Claude Code*'){'12460,18791'}else{'12460'}
   $_.Path+"`t"+$ports
  })
  $actual=@(Get-Content -LiteralPath (Join-Path $dir 'targets.tsv') -Encoding UTF8 -ErrorAction Stop)
  $coverage=$expected.Count -gt 0 -and $actual.Count -eq $expected.Count -and ($actual -join "`n") -ceq ($expected -join "`n")
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=Join-Path $dir 'LoopbackGuard.exe'
  $start.Arguments='audit "'+(Join-Path $dir 'targets.tsv')+'"'
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $p=[Diagnostics.Process]::Start($start)
  try {
   if(-not $p.WaitForExit(5000)){$p.Kill();throw 'WFP audit exceeded 5 seconds'}
   $output=$p.StandardOutput.ReadToEnd();$errorText=$p.StandardError.ReadToEnd()
   $rules=$p.ExitCode -eq 0
   $detail=($output+$errorText).Trim()
  }finally{$p.Dispose()}
 }catch{$detail=$_.Exception.Message}
 [pscustomobject]@{Name='Loopback: protected path and allowed-port coverage';Status=$(if($coverage){'pass'}else{'fail'});Detail='Only 127.0.0.1 TCP; Code 12460/18791, other protected Claude executables 12460'}
 [pscustomobject]@{Name='Loopback: persistent WFP filters intact';Status=$(if($rules){'pass'}else{'fail'});Detail=$detail}
}
